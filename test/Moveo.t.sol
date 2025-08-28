// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Moveo} from "../src/Moveo.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MoveoTest is Test {
    using MessageHashUtils for bytes32;

    Moveo public moveo;
    ERC20Mock public token;

    address public immutable owner = makeAddr("owner");
    uint256 public immutable serverPk = uint256(keccak256("server-private-key"));
    address public immutable server = vm.addr(serverPk);

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant INITIAL_BALANCE = 10000 ether;
    uint256 constant STAKE_AMOUNT = 100 ether;
    uint256 constant REWARD_AMOUNT = 10 ether;
    uint256 constant PENALTY_AMOUNT = 5 ether;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Rewarded(address indexed account, uint256 reward);
    event Slashed(address indexed account, uint256 penalty);
    event TreasuryDeposit(uint256 amount, address indexed token);
    event TreasuryWithdrawal(uint256 amount, address indexed token);
    event ServerAddressUpdated(address indexed oldServerAddr, address indexed newServerAddr);

    function setUp() public {
        // Deploy token
        token = new ERC20Mock();

        // Deploy Moveo contract
        vm.prank(owner);
        moveo = new Moveo(owner, server, address(token));

        // Setup initial balances
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        token.mint(charlie, INITIAL_BALANCE);
        token.mint(owner, INITIAL_BALANCE);

        // Approve Moveo contract
        vm.prank(alice);
        token.approve(address(moveo), type(uint256).max);
        vm.prank(bob);
        token.approve(address(moveo), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(moveo), type(uint256).max);
        vm.prank(owner);
        token.approve(address(moveo), type(uint256).max);
    }

    // ============ Helper Functions ============

    function signMessage(bytes32 messageHash, uint256 privateKey) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", moveo.domainSeparator(), messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function createUnstakeSignature(address user, uint256 amount) internal view returns (bytes memory) {
        bytes32 messageHash = moveo.hashUnstake(user, amount);
        return signMessage(messageHash, serverPk);
    }

    function createRewardSignature(address user, uint256 amount) internal view returns (bytes memory) {
        bytes32 messageHash = moveo.hashReward(user, amount);
        return signMessage(messageHash, serverPk);
    }

    function createPenaltySignature(address user, uint256 amount) internal view returns (bytes memory) {
        bytes32 messageHash = moveo.hashPenalty(user, amount);
        return signMessage(messageHash, serverPk);
    }

    // ============ Staking Tests ============

    function test_Stake_Success() public {
        vm.startPrank(alice);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit Staked(alice, STAKE_AMOUNT);

        moveo.stake(STAKE_AMOUNT);

        assertEq(token.balanceOf(alice), balanceBefore - STAKE_AMOUNT);
        assertEq(token.balanceOf(address(moveo)), STAKE_AMOUNT);

        (uint256 staked, uint256 lastUpdate) = moveo.accounts(alice);
        assertEq(staked, STAKE_AMOUNT);
        assertEq(lastUpdate, block.timestamp);
        assertEq(moveo.totalStakedAmount(), STAKE_AMOUNT);

        vm.stopPrank();
    }

    function test_Stake_Multiple() public {
        vm.startPrank(alice);
        moveo.stake(STAKE_AMOUNT);
        moveo.stake(STAKE_AMOUNT);
        vm.stopPrank();

        (uint256 staked,) = moveo.accounts(alice);
        assertEq(staked, STAKE_AMOUNT * 2);
        assertEq(moveo.totalStakedAmount(), STAKE_AMOUNT * 2);
    }

    function test_Stake_MultipleUsers() public {
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        vm.prank(bob);
        moveo.stake(STAKE_AMOUNT * 2);

        (uint256 aliceStaked,) = moveo.accounts(alice);
        (uint256 bobStaked,) = moveo.accounts(bob);

        assertEq(aliceStaked, STAKE_AMOUNT);
        assertEq(bobStaked, STAKE_AMOUNT * 2);
        assertEq(moveo.totalStakedAmount(), STAKE_AMOUNT * 3);
    }

    function test_Stake_RevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(Moveo.InvalidAmount.selector);
        moveo.stake(0);
    }

    // ============ Unstaking Tests ============

    function test_Unstake_WithSignature() public {
        // First stake
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        // Create signature for unstaking
        bytes memory signature = createUnstakeSignature(alice, STAKE_AMOUNT);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit Unstaked(alice, STAKE_AMOUNT);

        vm.prank(alice);
        moveo.unstake(alice, STAKE_AMOUNT, signature);

        assertEq(token.balanceOf(alice), balanceBefore + STAKE_AMOUNT);
        (uint256 staked,) = moveo.accounts(alice);
        assertEq(staked, 0);
        assertEq(moveo.totalStakedAmount(), 0);
    }

    function test_Unstake_PartialAmount() public {
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        uint256 unstakeAmount = STAKE_AMOUNT / 2;
        bytes memory signature = createUnstakeSignature(alice, unstakeAmount);

        vm.prank(alice);
        moveo.unstake(alice, unstakeAmount, signature);

        (uint256 staked,) = moveo.accounts(alice);
        assertEq(staked, STAKE_AMOUNT - unstakeAmount);
    }

    function test_Unstake_ByOwner() public {
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        // Owner can unstake on behalf of user without signature
        vm.prank(owner);
        moveo.unstake(alice, STAKE_AMOUNT, "");

        assertEq(token.balanceOf(alice), aliceBalanceBefore + STAKE_AMOUNT);
        (uint256 staked,) = moveo.accounts(alice);
        assertEq(staked, 0);
    }

    function test_Unstake_RevertInsufficientBalance() public {
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        bytes memory signature = createUnstakeSignature(alice, STAKE_AMOUNT * 2);

        vm.prank(alice);
        vm.expectRevert(Moveo.InsufficientBalance.selector);
        moveo.unstake(alice, STAKE_AMOUNT * 2, signature);
    }

    function test_Unstake_RevertInvalidSignature() public {
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        // Create invalid signature
        bytes memory invalidSignature = createUnstakeSignature(bob, STAKE_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(Moveo.InvalidServerSignature.selector);
        moveo.unstake(alice, STAKE_AMOUNT, invalidSignature);
    }

    function test_Unstake_RevertZeroAmount() public {
        bytes memory signature = createUnstakeSignature(alice, 0);

        vm.prank(alice);
        vm.expectRevert(Moveo.InvalidAmount.selector);
        moveo.unstake(alice, 0, signature);
    }

    // ============ Reward Tests ============

    function test_Reward_Success() public {
        // Add funds to treasury
        vm.prank(owner);
        moveo.addToTreasury(REWARD_AMOUNT * 10, address(token));

        bytes memory signature = createRewardSignature(alice, REWARD_AMOUNT);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit Rewarded(alice, REWARD_AMOUNT);

        vm.prank(owner);
        moveo.reward(alice, REWARD_AMOUNT, signature);

        assertEq(token.balanceOf(alice), balanceBefore + REWARD_AMOUNT);
        assertEq(moveo.treasury(address(token)), REWARD_AMOUNT * 10 - REWARD_AMOUNT);
    }

    function test_Reward_RevertNotOwner() public {
        vm.prank(owner);
        moveo.addToTreasury(REWARD_AMOUNT * 10, address(token));

        bytes memory signature = createRewardSignature(alice, REWARD_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        moveo.reward(alice, REWARD_AMOUNT, signature);
    }

    function test_Reward_RevertInsufficientTreasury() public {
        bytes memory signature = createRewardSignature(alice, REWARD_AMOUNT);

        vm.prank(owner);
        vm.expectRevert(Moveo.InsufficientTreasuryFunds.selector);
        moveo.reward(alice, REWARD_AMOUNT, signature);
    }

    function test_Reward_RevertZeroAmount() public {
        bytes memory signature = createRewardSignature(alice, 0);

        vm.prank(owner);
        vm.expectRevert(Moveo.InvalidAmount.selector);
        moveo.reward(alice, 0, signature);
    }

    // ============ Slash Tests ============

    function test_Slash_Success() public {
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        bytes memory signature = createPenaltySignature(alice, PENALTY_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit Slashed(alice, PENALTY_AMOUNT);

        vm.prank(owner);
        moveo.slash(alice, PENALTY_AMOUNT, signature);

        (uint256 staked,) = moveo.accounts(alice);
        assertEq(staked, STAKE_AMOUNT - PENALTY_AMOUNT);
        assertEq(moveo.totalStakedAmount(), STAKE_AMOUNT - PENALTY_AMOUNT);
        assertEq(moveo.treasury(address(token)), PENALTY_AMOUNT);
    }

    function test_Slash_RevertInsufficientStake() public {
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        bytes memory signature = createPenaltySignature(alice, STAKE_AMOUNT * 2);

        vm.prank(owner);
        vm.expectRevert(Moveo.InsufficientBalance.selector);
        moveo.slash(alice, STAKE_AMOUNT * 2, signature);
    }

    function test_Slash_RevertNotOwner() public {
        bytes memory signature = createPenaltySignature(alice, PENALTY_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        moveo.slash(alice, PENALTY_AMOUNT, signature);
    }

    function test_Slash_RevertZeroAmount() public {
        bytes memory signature = createPenaltySignature(alice, 0);

        vm.prank(owner);
        vm.expectRevert(Moveo.InvalidAmount.selector);
        moveo.slash(alice, 0, signature);
    }

    // ============ Treasury Tests ============

    function test_AddToTreasury() public {
        uint256 amount = 1000 ether;

        vm.expectEmit(true, true, false, true);
        emit TreasuryDeposit(amount, address(token));

        vm.prank(owner);
        moveo.addToTreasury(amount, address(token));

        assertEq(moveo.treasury(address(token)), amount);
        assertEq(token.balanceOf(address(moveo)), amount);
    }

    function test_RemoveFromTreasury() public {
        uint256 amount = 1000 ether;

        vm.prank(owner);
        moveo.addToTreasury(amount, address(token));

        uint256 withdrawAmount = 500 ether;

        vm.expectEmit(true, true, false, true);
        emit TreasuryWithdrawal(withdrawAmount, address(token));

        vm.prank(owner);
        moveo.removeFromTreasury(withdrawAmount, address(token), bob);

        assertEq(moveo.treasury(address(token)), amount - withdrawAmount);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE + withdrawAmount);
    }

    function test_RemoveFromTreasury_RevertInsufficientFunds() public {
        vm.prank(owner);
        vm.expectRevert(Moveo.InsufficientTreasuryFunds.selector);
        moveo.removeFromTreasury(1000 ether, address(token), bob);
    }

    // ============ View Functions Tests ============

    function test_GetAccountDetails() public {
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        Moveo.Account memory account = moveo.getAccountDetails(alice);
        assertEq(account.staked, STAKE_AMOUNT);
        assertEq(account.lastUpdate, block.timestamp);
    }

    function test_GetAccountDetails_RevertInvalidAccount() public {
        vm.expectRevert(Moveo.InvalidAccount.selector);
        moveo.getAccountDetails(alice);
    }

    function test_Liquidity() public {
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        vm.prank(owner);
        moveo.addToTreasury(1000 ether, address(token));

        (uint256 balance, uint256 treasury, uint256 totalStaked) = moveo.liquidity();
        assertEq(balance, STAKE_AMOUNT + 1000 ether);
        assertEq(treasury, 1000 ether);
        assertEq(totalStaked, STAKE_AMOUNT);
    }

    // ============ Server Address Update Tests ============

    function test_UpdateServerAddress() public {
        address newServer = makeAddr("newServer");

        vm.expectEmit(true, true, false, false);
        emit ServerAddressUpdated(server, newServer);

        vm.prank(owner);
        moveo.updateServerAddress(newServer);

        assertEq(moveo.server(), newServer);
    }

    function test_UpdateServerAddress_RevertNotOwner() public {
        address newServer = makeAddr("newServer");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        moveo.updateServerAddress(newServer);
    }

    // ============ EIP712 Tests ============

    function test_DomainSeparator() public view {
        bytes32 domainSeparator = moveo.domainSeparator();
        assertNotEq(domainSeparator, bytes32(0));
    }

    function test_TypeHashes() public view {
        assertEq(moveo.UNSTAKE_TYPEHASH(), keccak256("Unstake(address user,uint256 amount)"));
        assertEq(moveo.REWARD_TYPEHASH(), keccak256("Reward(address user,uint256 amount)"));
        assertEq(moveo.PENALTY_TYPEHASH(), keccak256("Penalty(address user,uint256 amount)"));
    }

    // ============ Integration Tests ============

    function test_Integration_FullFlow() public {
        // Alice stakes
        vm.prank(alice);
        moveo.stake(STAKE_AMOUNT);

        // Bob stakes
        vm.prank(bob);
        moveo.stake(STAKE_AMOUNT * 2);

        // Owner adds to treasury
        vm.prank(owner);
        moveo.addToTreasury(1000 ether, address(token));

        // Owner rewards Alice
        bytes memory rewardSig = createRewardSignature(alice, REWARD_AMOUNT);
        vm.prank(owner);
        moveo.reward(alice, REWARD_AMOUNT, rewardSig);

        // Owner slashes Bob
        bytes memory penaltySig = createPenaltySignature(bob, PENALTY_AMOUNT);
        vm.prank(owner);
        moveo.slash(bob, PENALTY_AMOUNT, penaltySig);

        // Alice unstakes partially
        bytes memory unstakeSig = createUnstakeSignature(alice, STAKE_AMOUNT / 2);
        vm.prank(alice);
        moveo.unstake(alice, STAKE_AMOUNT / 2, unstakeSig);

        // Verify final state
        (uint256 aliceStaked,) = moveo.accounts(alice);
        (uint256 bobStaked,) = moveo.accounts(bob);

        assertEq(aliceStaked, STAKE_AMOUNT / 2);
        assertEq(bobStaked, STAKE_AMOUNT * 2 - PENALTY_AMOUNT);
        assertEq(moveo.totalStakedAmount(), STAKE_AMOUNT / 2 + STAKE_AMOUNT * 2 - PENALTY_AMOUNT);
        assertEq(moveo.treasury(address(token)), 1000 ether - REWARD_AMOUNT + PENALTY_AMOUNT);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Stake(uint256 amount) public {
        amount = bound(amount, 1, INITIAL_BALANCE);

        vm.prank(alice);
        moveo.stake(amount);

        (uint256 staked,) = moveo.accounts(alice);
        assertEq(staked, amount);
        assertEq(moveo.totalStakedAmount(), amount);
    }

    function testFuzz_UnstakeWithSignature(uint256 stakeAmount, uint256 unstakeAmount) public {
        stakeAmount = bound(stakeAmount, 1, INITIAL_BALANCE);
        unstakeAmount = bound(unstakeAmount, 1, stakeAmount);

        vm.prank(alice);
        moveo.stake(stakeAmount);

        bytes memory signature = createUnstakeSignature(alice, unstakeAmount);

        vm.prank(alice);
        moveo.unstake(alice, unstakeAmount, signature);

        (uint256 staked,) = moveo.accounts(alice);
        assertEq(staked, stakeAmount - unstakeAmount);
    }

    function testFuzz_RewardAndSlash(uint256 stakeAmount, uint256 rewardAmount, uint256 penaltyAmount) public {
        stakeAmount = bound(stakeAmount, 2, INITIAL_BALANCE);
        penaltyAmount = bound(penaltyAmount, 1, stakeAmount);
        rewardAmount = bound(rewardAmount, 1, INITIAL_BALANCE);

        // Setup
        vm.prank(alice);
        moveo.stake(stakeAmount);

        vm.prank(owner);
        moveo.addToTreasury(rewardAmount * 2, address(token));

        // Reward
        bytes memory rewardSig = createRewardSignature(alice, rewardAmount);
        vm.prank(owner);
        moveo.reward(alice, rewardAmount, rewardSig);

        // Slash
        bytes memory penaltySig = createPenaltySignature(alice, penaltyAmount);
        vm.prank(owner);
        moveo.slash(alice, penaltyAmount, penaltySig);

        // Verify
        (uint256 staked,) = moveo.accounts(alice);
        assertEq(staked, stakeAmount - penaltyAmount);
        assertEq(moveo.treasury(address(token)), rewardAmount * 2 - rewardAmount + penaltyAmount);
    }
}
