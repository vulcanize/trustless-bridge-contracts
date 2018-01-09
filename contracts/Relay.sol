pragma solidity ^0.4.18;

import "./MerkleLib.sol";
import "tokens/Token.sol";  // truffle package (install with `truffle install tokens`)
import "tokens/HumanStandardToken.sol";

contract Relay {

  // ===========================================================================
  // GLOBAL VARIABLES
  // ===========================================================================

  // This maps the start block and end block for a given chain to an epoch
  // index (i) and provides the root.
  event HeaderRoot(address indexed chain, uint256 indexed start,
    uint256 indexed end, bytes32 root, uint256 i, address proposer);
  event Deposit(address indexed user, address indexed toChain,
    address indexed token, uint256 amount);
  event Withdraw(address indexed user, address indexed fromChain,
    address indexed token, uint256 amount);
  event TokenAdded(address indexed fromChain, address indexed origToken,
    address indexed newToken);

  // Admin has the ability to add tokens to the relay
  address public admin;

  // The reward function, which is of form (reward = base + a*n)
  // where n is the number of blocks proposed in the header (end-start)
  struct Reward {
    uint256 base;
    uint256 a;
  }
  Reward reward;
  uint256 public maxReward;

  // Reward for successfully contesting a headerRoot
  uint256 public bountyWei;

  // The randomness seed of the epoch. This is used to determine the proposer
  // and the validator pool
  bytes32 public epochSeed = block.blockhash(block.number-1);

  // Global pool of stakers - indexed by address leading to stake size
  struct Stake {
    uint256 amount;
    address staker;
  }
  mapping(address => uint64) stakers;
  Stake[] stakes;
  uint256 public stakeSum;
  address stakeToken;
  uint64 validatorThreshold = 0;

  // Pending withdrawals. The user prepares a withdrawal with tx data and then
  // releases it with a withdraw. It can be overwritten by the user and gets wiped
  // upon withdrawal.
  struct Withdrawal {
    address token;
    uint256 amount;
    bytes32 txHash;
  }
  mapping(address => Withdrawal) pendingWithdrawals;

  // The root of a Merkle tree made of consecutive block headers.
  // These are indexed by the chainId of the Relay contract on the
  // sidechain. This also serves as the identity of the chain itself.
  // The associatin between address-id and chain-id is stored off-chain but it
  // must be 1:1 and unique.
  mapping(address => bytes32[]) headerRoots;

  // Tokens need to be associated between chains. For now, only the admin can
  // create and map tokens on the sidechain to tokens on the main chain
  // fromChainId => (oldTokenAddr => newTokenAddr)
  mapping(address => mapping(address => address)) tokens;

  // ===========================================================================
  // STAKER FUNCTIONS
  // ===========================================================================

  // Stake a specified quantity of the staking token
  function stake(uint256 amount) public {
    HumanStandardToken t = HumanStandardToken(stakeToken);
    t.transferFrom(msg.sender, address(this), amount);
    // We can't have a 0-length stakes array
    if (stakes.length == 0) { stakes.push(s); }
    if (stakers[msg.sender] == 0) {
      // If the staker is new
      Stake memory s;
      s.amount = amount;
      s.staker = msg.sender;
      stakes.push(s);
      stakers[msg.sender] = uint64(stakes.length) - 1;
    } else {
      // Otherwise we can just add to the stake
      stakes[stakers[msg.sender]].amount += amount;
    }
    stakeSum += amount;
  }

  // Remove stake
  function destake(uint256 amount) public {
    assert(stakers[msg.sender] != 0);
    assert(amount <= stakes[stakers[msg.sender]].amount);
    stakes[stakers[msg.sender]].amount -= amount;
    stakeSum -= amount;
    HumanStandardToken t = HumanStandardToken(stakeToken);
    t.transfer(msg.sender, amount);
    if (stakes[stakers[msg.sender]].amount == 0) {
      delete stakes[stakers[msg.sender]];
    }
  }

  // Save a hash to an append-only array of headerRoots associated with the
  // given origin chain address-id.
  function proposeRoot(bytes32 root, address chainId, uint256 start, uint256 end,
  bytes sigs) public {
    // Make sure enough validators sign off on the proposed header root
    assert(checkSignatures(root, chainId, start, end, sigs) == true);
    // Add the header root
    headerRoots[chainId].push(root);
    // Calculate the reward and issue it
    uint256 r = reward.base + reward.a * (end - start);
    // If we exceed the max reward, anyone can propose the header root
    if (r > maxReward) {
      r = maxReward;
    } else {
      assert(msg.sender == getProposer());
    }
    msg.sender.transfer(r);
    epochSeed = block.blockhash(block.number);
    HeaderRoot(chainId, start, end, root, headerRoots[chainId].length, msg.sender);
  }

  // ===========================================================================
  // ADMIN FUNCTIONS
  // ===========================================================================

  // Map a token (or ether) to a token on the original chain
  function addToken(address newToken, address origToken, address fromChain)
  public payable onlyAdmin() {
    // Ether is represented as address(1). We don't need to map the entire supply
    // because actors need ether to do anything on this chain. We'll assume
    // the accounting is managed off-chain.
    if (newToken != address(1)) {
      // Adding ERC20 tokens is stricter. We need to map the total supply.
      assert(newToken != address(0));
      HumanStandardToken t = HumanStandardToken(newToken);
      t.transferFrom(msg.sender, address(this), t.totalSupply());
      tokens[fromChain][origToken] = newToken;
    }
    TokenAdded(fromChain, origToken, newToken);
  }

  // Change the number of validators required to allow a passed header root
  function updateValidatorThreshold(uint64 newThreshold) public onlyAdmin() {
    validatorThreshold = newThreshold;
  }

  // The admin can update the reward at any time.
  // TODO: We may want to block this during the current epoch, which would require
  // we keep a "reward cache" of some kind.
  function updateReward(uint256 base, uint256 a, uint256 max) public {
    reward.base = base;
    reward.a = a;
    maxReward = max;
  }

  // ===========================================================================
  // USER FUNCTIONS
  // ===========================================================================

  // Any user may make a deposit bound for a particular chainId (address of
  // relay on the destination chain).
  // Only tokens for now, but ether may be allowed later.
  function deposit(address token, address toChain, uint256 amount) public payable {
    assert(tokens[toChain][token] != address(0));
    HumanStandardToken t = HumanStandardToken(token);
    t.transferFrom(msg.sender, address(this), amount);
    Deposit(msg.sender, toChain, address(this), amount);
  }


  // The user who wishes to make a withdrawal sets the transaction here.
  // This must correspond to `deposit()` on the fromChain
  // fields = [nonce, gasPrice, gasLimit, value, r, s]
  // This is a separated function to avoid stack overflows and excessive gas costs
  function prepWithdraw(address token, address fromChain, uint256 amount,
  bytes32[6] fields, uint8 v, bytes4 fPrefix) public {
    // Form the transaction data. It should be [token, fromChain, amount]
    bytes memory txData;
    // Thanks @GNSPS for the assembly!
    assembly {
      txData := mload(0x40)
      // Assign 100 bytes for the data
      mstore(0x40, add(txData, 0x84))

      mstore(txData, 0x64)
      txData := add(txData, 0x20)

      mstore(txData, mload(fPrefix))
      txData := add(txData, 4)

      txData := add(txData, mload(amount))
      txData := add(txData, 0x20)

      txData := add(txData, mload(fromChain))
      txData := add(txData, 0x20)

      txData := add(txData, mload(token))
      txData := add(txData, 0x20)
    }
    // Form the txHash. Order determined using ethereumjs-tx:
    // https://github.com/ethereumjs/ethereumjs-tx/blob/master/index.js#L47
    bytes32 txHash = keccak256(fields[0], fields[1], fields[2], fromChain, fields[3],
      txData, v, fields[4], fields[5]);
    Withdrawal memory w;
    w.txHash = txHash;
    w.token = token;
    w.amount = amount;
    pendingWithdrawals[msg.sender] = w;
  }

  // To withdraw a token, the user needs to perform three proofs:
  // 1. Prove that the transaction was included in a transaction Merkle tree
  // 2. Prove that the tx Merkle root went in to forming a block header
  // 3. Prove that the block header went into forming the header root of an epoch
  // Data is of form: [txTreeDepth, txProof, block header data, headerTreeDepth,
  // headerProof]
  //
  // Note: Because the history is based on social consensus, the block headers
  // can actually be different than what exists in the canonical blockchain.
  // We can vastly simplify the block data!
  //
  // indices = locations within the Merkle tree [ tx, header ]
  // loc = location of the header root
  function withdraw(address fromChain, uint64[2] indices, uint64 loc, bytes data) public {
    // 1. Transaction proof
    // First 8 bytes are txTreeDepth
    Withdrawal memory w = pendingWithdrawals[msg.sender];
    uint64 offset = 8 + txProof(w.txHash, 8, indices[0], data);

    // 2. Prove block header root
    offset = headerProof(offset, indices[1], fromChain, loc, data);

    // If both proofs succeeded, we can make the withdrawal of tokens!
    HumanStandardToken t = HumanStandardToken(w.token);
    t.transfer(msg.sender, w.amount);
    Withdraw(msg.sender, fromChain, w.token, w.amount);
    delete pendingWithdrawals[msg.sender];
  }

  // ===========================================================================
  // UTILITY FUNCTIONS
  // ===========================================================================


  function txProof(bytes32 txHash, uint64 offset, uint64 index, bytes data)
  internal constant returns (uint64) {
    bytes32[] memory proof = new bytes32[](MerkleLib.getUint64(0, data));
    proof[0] = txHash;
    // Now fill in the Merkle proof for transactions
    for (uint64 t = 0; t < MerkleLib.getUint64(0, data); t++) {
      proof[t + 1] = MerkleLib.getBytes32(offset + t * 32, data);
    }
    offset += (t - 1) * 32;
    // Do the transaction proof
    assert(
      MerkleLib.merkleProof(
        index,
        proof[proof.length - 1],
        offset,
        data
      ) == true
    );
    return offset;
  }

  function headerProof(uint64 offset, uint64 index, address fromChain, uint64 loc,
  bytes data) internal constant returns (uint64) {
    uint64 headerTreeDepth = MerkleLib.getUint64(offset, data);
    bytes32[] memory proof = new bytes32[](headerTreeDepth);
    // Form the block header we are trying to prove
    // hash(prevHash, timestamp, blockNum, txRoot)
    proof[0] = keccak256(
      MerkleLib.getBytes32(offset + 8, data),
      MerkleLib.getBytes32(offset + 40, data),
      MerkleLib.getBytes32(offset + 72, data),
      proof[proof.length - 1]
    );
    offset += 104;

    // Fill the Merkle proof for headers
    for (uint64 h = 0; h < MerkleLib.getUint64(0, data); h++) {
      proof[h + 1] = MerkleLib.getBytes32(offset + (h * 32), data);
    }
    offset += (h - 1) * 32;

    // Do the proof
    assert(
      MerkleLib.merkleProof(
        index,
        headerRoots[fromChain][loc],
        offset,
        data
      ) == true
    );
    return offset;
  }

  // Check a series of signatures against staker addresses. If there are enough
  // signatures (>= validatorThreshold), return true
  // NOTE: For the first version, any staker will work. For the future, we should
  // select a subset of validators from the staker pool.
  function checkSignatures(bytes32 root, address chain, uint256 start, uint256 end,
  bytes sigs) internal returns (bool) {
    bytes32 h = keccak256(root, chain, start, end);
    address valTmp;
    address[] passing;
    // signs are chunked in 65 bytes -> [r, s, v]
    for (uint64 i = 0; i < sigs.length / 65; i ++) {
      valTmp = ecrecover(
        h,
        uint8(sigs[i * 65 + 64]),
        MerkleLib.getBytes32(i * 65, sigs),
        MerkleLib.getBytes32(i * 65 + 32, sigs)
      );
      // Make sure this address is a staker and NOT the proposer
      assert(stakers[valTmp] != 0);
      assert(valTmp != getProposer());
      // Unfortunately we need to loop through the cache to make sure there are
      // no signature duplicates. This is the most efficient way to do it since
      // storage costs too much.
      for (uint j = 0; j < passing.length; j ++) {
        assert(passing[j] != valTmp);
      }
      passing.push(valTmp);
    }
    return passing.length >= validatorThreshold;
  }

  // Sample a proposer. Likelihood of being chosen is proportional to stake size.
  // NOTE: This is just a first pass. This will bias earlier stakers
  // and should be fixed to be made more fair
  function getProposer() public constant returns (address) {
    // Convert the seed to an index
    uint256 target = uint256(epochSeed) % stakeSum;
    // Index of stakes
    uint64 i = 1;
    // Total stake
    uint256 sum = 0;
    while (sum < target) {
      sum += stakes[i].amount;
      i += 1;
    }
    // Winner winner chicken dinner
    return stakes[i - 1].staker;
  }

  // Staking token can only be set at instantiation!
  function Relay(address token) {
    admin = msg.sender;
    stakeToken = token;
  }

  modifier onlyAdmin() {
    require(msg.sender == admin);
    _;
  }

  function() public payable {}

}
