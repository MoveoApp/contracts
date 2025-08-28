// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Moveo is Ownable, EIP712 {
    using SafeERC20 for IERC20;

    struct Account {
        uint256 staked;
        uint256 lastUpdate;
    }

    IERC20 public immutable token;
    address public server;
    uint256 public totalStakedAmount;
    mapping(address => Account) public accounts;
    mapping(address => uint256) public treasury;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Rewarded(address indexed account, uint256 reward);
    event Slashed(address indexed account, uint256 penalty);
    event TreasuryDeposit(uint256 amount, address indexed token);
    event TreasuryWithdrawal(uint256 amount, address indexed token);
    event ServerAddressUpdated(address indexed oldServerAddr, address indexed newServerAddr);

    error InsufficientBalance();
    error InvalidAccount();
    error InsufficientTreasuryFunds();
    error InvalidServerSignature();
    error DeadlineExpired();
    error InvalidAmount();

    constructor(address _owner, address _server, address _token) Ownable(_owner) EIP712("Moveo", "1") {
        server = _server;
        token = IERC20(_token);
    }

    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    bytes32 public constant UNSTAKE_TYPEHASH = keccak256("Unstake(address user,uint256 amount)");

    bytes32 public constant REWARD_TYPEHASH = keccak256("Reward(address user,uint256 amount)");

    bytes32 public constant PENALTY_TYPEHASH = keccak256("Penalty(address user,uint256 amount)");

    function hashUnstake(address user, uint256 amount) public pure returns (bytes32) {
        return keccak256(abi.encode(UNSTAKE_TYPEHASH, user, amount));
    }

    function hashReward(address user, uint256 amount) public pure returns (bytes32) {
        return keccak256(abi.encode(REWARD_TYPEHASH, user, amount));
    }

    function hashPenalty(address user, uint256 amount) public pure returns (bytes32) {
        return keccak256(abi.encode(PENALTY_TYPEHASH, user, amount));
    }

    function stake(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        Account storage a = accounts[msg.sender];
        a.staked += amount;
        a.lastUpdate = block.timestamp;
        totalStakedAmount += amount;

        token.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    function unstake(address user, uint256 amount, bytes calldata signature) external {
        if (amount == 0) revert InvalidAmount();

        // If not owner, verify signature for user's unstake
        if (msg.sender != owner()) {
            bytes32 messageHash = hashUnstake(user, amount);
            _verifyAnyAdminSignature(messageHash, signature);
        }

        // Allow owner to unstake on behalf of user, or user with valid signature
        address account = (msg.sender == owner()) ? user : msg.sender;

        Account storage a = accounts[account];
        if (a.staked < amount) revert InsufficientBalance();

        a.staked -= amount;
        a.lastUpdate = block.timestamp;
        totalStakedAmount -= amount;

        token.safeTransfer(account, amount);

        emit Unstaked(account, amount);
    }

    function reward(address user, uint256 amount, bytes calldata signature) external onlyOwner {
        if (amount == 0) revert InvalidAmount();

        bytes32 messageHash = hashReward(user, amount);
        _verifyAnyAdminSignature(messageHash, signature);

        if (treasury[address(token)] < amount) revert InsufficientTreasuryFunds();

        treasury[address(token)] -= amount;
        token.safeTransfer(user, amount);

        emit Rewarded(user, amount);
    }

    function slash(address user, uint256 penalty, bytes calldata signature) external onlyOwner {
        if (penalty == 0) revert InvalidAmount();

        bytes32 messageHash = hashPenalty(user, penalty);
        _verifyAnyAdminSignature(messageHash, signature);

        Account storage a = accounts[user];
        if (a.staked < penalty) revert InsufficientBalance();

        a.staked -= penalty;
        totalStakedAmount -= penalty;
        treasury[address(token)] += penalty;

        emit Slashed(user, penalty);
    }

    function getAccountDetails(address user) external view returns (Account memory) {
        if (accounts[user].lastUpdate == 0) revert InvalidAccount();
        return accounts[user];
    }

    function liquidity() external view returns (uint256, uint256, uint256) {
        return (token.balanceOf(address(this)), treasury[address(token)], totalStakedAmount);
    }

    function addToTreasury(uint256 amount, address _token) external onlyOwner {
        if (amount == 0) revert InvalidAmount();

        treasury[_token] += amount;
        IERC20(_token).safeTransferFrom(msg.sender, address(this), amount);

        emit TreasuryDeposit(amount, _token);
    }

    function removeFromTreasury(uint256 amount, address _token, address recipient) external onlyOwner {
        if (amount == 0) revert InvalidAmount();
        if (treasury[_token] < amount) revert InsufficientTreasuryFunds();

        treasury[_token] -= amount;
        IERC20(_token).safeTransfer(recipient, amount);

        emit TreasuryWithdrawal(amount, _token);
    }

    function updateServerAddress(address _server) external onlyOwner {
        emit ServerAddressUpdated(server, _server);

        server = _server;
    }

    function _verifyAnyAdminSignature(bytes32 _hash, bytes calldata _signature) internal view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), _hash));
        if (!SignatureChecker.isValidSignatureNow(server, digest, _signature)) revert InvalidServerSignature();
    }
}
