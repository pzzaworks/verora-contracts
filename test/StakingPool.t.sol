// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IntegrationBase} from "./integration/Base.t.sol";
import {StakingPool} from "../src/StakingPool.sol";
import {IStakingPool} from "../src/interfaces/IStakingPool.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";

contract StakingPoolTest is IntegrationBase {
    bytes32 internal agentA;

    function setUp() public override {
        super.setUp();
        agentA = _registerAgent(alice, ENDPOINT_ALICE);
    }

    function _stake(address staker, uint256 amount) internal {
        vm.prank(staker);
        staking.stake{value: amount}(agentA);
    }

    /*//////////////////////////////////////////////////////////////
                                 STAKE
    //////////////////////////////////////////////////////////////*/

    function test_Stake_MintsSharesAndTracksStakers() public {
        _stake(bob, 1 ether);
        _stake(charlie, 2 ether);

        assertEq(staking.getTotalStake(agentA), 3 ether);
        assertEq(staking.getStakerCount(agentA), 2);
        assertEq(_getStake(agentA, bob).amount, 1 ether);
        assertEq(_getStake(agentA, charlie).shares, 2 ether);
    }

    function test_Stake_RevertsBelowMinimumInactiveOrPaused() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.InsufficientStake.selector, MINIMUM_STAKE, 1));
        staking.stake{value: 1}(agentA);

        vm.prank(alice);
        registry.suspendAgent(agentA, "off");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.AgentNotActive.selector, agentA));
        staking.stake{value: 1 ether}(agentA);

        vm.prank(alice);
        registry.reactivateAgent(agentA);
        vm.prank(deployer);
        staking.pause();
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.stake{value: 1 ether}(agentA);
    }

    /*//////////////////////////////////////////////////////////////
                           UNSTAKE / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_Unstake_StartsUnbondingAndWithdrawAfterPeriod() public {
        _stake(bob, 1 ether);

        vm.prank(bob);
        staking.unstake(agentA, 0.4 ether);

        IStakingPool.StakeInfo memory info = _getStake(agentA, bob);
        assertEq(info.amount, 0.6 ether);
        assertEq(info.unbondingAmount, 0.4 ether);
        assertEq(info.nextUnlockTime, block.timestamp + UNSTAKING_PERIOD);
        assertEq(staking.getTotalStake(agentA), 0.6 ether);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(StakingPool.UnstakingPeriodNotElapsed.selector, block.timestamp + UNSTAKING_PERIOD)
        );
        staking.withdraw(agentA);

        vm.warp(block.timestamp + UNSTAKING_PERIOD);
        uint256 before = bob.balance;
        vm.prank(bob);
        staking.withdraw(agentA);
        assertEq(bob.balance, before + 0.4 ether);
    }

    /// @dev Audit regression: each new unstake used to reset the unlock time of the whole pending amount
    function test_Unstake_RequestsUnlockIndependently() public {
        _stake(bob, 1 ether);

        vm.prank(bob);
        staking.unstake(agentA, 0.3 ether);
        vm.warp(block.timestamp + UNSTAKING_PERIOD - 1);
        vm.prank(bob);
        staking.unstake(agentA, 0.3 ether);

        vm.warp(block.timestamp + 1);
        uint256 before = bob.balance;
        vm.prank(bob);
        staking.withdraw(agentA);
        assertEq(bob.balance, before + 0.3 ether);
        assertEq(_getStake(agentA, bob).unbondingAmount, 0.3 ether);
    }

    function test_Unstake_AllWithMaxAndStakerCount() public {
        _stake(bob, 1 ether);
        vm.prank(bob);
        staking.unstake(agentA, type(uint256).max);

        assertEq(_getStake(agentA, bob).shares, 0);
        assertEq(staking.getStakerCount(agentA), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.InsufficientBalance.selector, 1, 0));
        staking.unstake(agentA, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                REWARDS
    //////////////////////////////////////////////////////////////*/

    function test_Rewards_AreProRataAndClaimable() public {
        _stake(bob, 1 ether);
        _stake(charlie, 3 ether);

        staking.distributeRewards{value: 4 ether}(agentA);

        assertEq(_getStake(agentA, bob).pendingRewards, 1 ether);
        assertEq(_getStake(agentA, charlie).pendingRewards, 3 ether);

        uint256 before = bob.balance;
        vm.prank(bob);
        staking.claimRewards(agentA);
        assertEq(bob.balance, before + 1 ether);

        vm.prank(bob);
        vm.expectRevert(StakingPool.NothingToClaim.selector);
        staking.claimRewards(agentA);
    }

    function test_Rewards_UnbondingSharesDoNotEarn() public {
        _stake(bob, 1 ether);
        _stake(charlie, 1 ether);
        vm.prank(bob);
        staking.unstake(agentA, type(uint256).max);

        staking.distributeRewards{value: 1 ether}(agentA);

        assertEq(_getStake(agentA, bob).pendingRewards, 0);
        assertEq(_getStake(agentA, charlie).pendingRewards, 1 ether);
    }

    function test_Rewards_WithoutStakersGoToTreasury() public {
        staking.distributeRewards{value: 1 ether}(agentA);
        assertEq(address(treasury).balance, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                SLASHING
    //////////////////////////////////////////////////////////////*/

    function test_Slash_IsProRataAndMarksAgent() public {
        _stake(bob, 1 ether);
        _stake(charlie, 3 ether);

        vm.prank(deployer);
        staking.slash(agentA, 2500, "bad data");

        assertEq(address(treasury).balance, 1 ether);
        assertEq(_getStake(agentA, bob).amount, 0.75 ether);
        assertEq(_getStake(agentA, charlie).amount, 2.25 ether);
        assertEq(uint8(registry.getAgentStatus(agentA)), uint8(IAgentRegistry.AgentStatus.Slashed));
    }

    /// @dev Audit regression: rounding left the sum of stakes above the total, so the last unstake reverted
    function test_Slash_RoundingNeverBlocksFullExit() public {
        _stake(bob, 0.1 ether + 1);
        _stake(charlie, 0.1 ether + 1);

        vm.prank(deployer);
        staking.slash(agentA, 5000, "bad data");

        vm.prank(bob);
        staking.unstake(agentA, type(uint256).max);
        vm.prank(charlie);
        staking.unstake(agentA, type(uint256).max);
        vm.warp(block.timestamp + UNSTAKING_PERIOD);
        vm.prank(bob);
        staking.withdraw(agentA);
        vm.prank(charlie);
        staking.withdraw(agentA);

        assertEq(staking.getPool(agentA).pooled, 0);
        assertEq(staking.getPool(agentA).totalShares, 0);
    }

    /// @dev Audit regression: a second slash on an already slashed agent used to revert
    function test_Slash_CanBeRepeated() public {
        _stake(bob, 1 ether);

        vm.startPrank(deployer);
        staking.slash(agentA, 5000, "first");
        staking.slash(agentA, 5000, "second");
        vm.stopPrank();

        assertEq(_getStake(agentA, bob).amount, 0.25 ether);
    }

    /// @dev Audit regression: stakers could front-run a slash by unstaking
    function test_Slash_HitsUnbondingStake() public {
        _stake(bob, 1 ether);
        vm.prank(bob);
        staking.unstake(agentA, type(uint256).max);

        vm.prank(deployer);
        staking.slash(agentA, 5000, "bad data");

        assertEq(_getStake(agentA, bob).unbondingAmount, 0.5 ether);
    }

    function test_Slash_RejectsInvalidPercentageAndUnauthorized() public {
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.InvalidSlashPercentage.selector, 5001));
        staking.slash(agentA, 5001, "too much");
        vm.expectRevert(abi.encodeWithSelector(StakingPool.InvalidSlashPercentage.selector, 0));
        staking.slash(agentA, 0, "nothing");
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.NotAuthorizedSlasher.selector, bob));
        staking.slash(agentA, 100, "x");
    }

    function test_Admin_UnstakingPeriodIsBounded() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.InvalidUnstakingPeriod.selector, 31 days));
        staking.setUnstakingPeriod(31 days);
    }

    /// @dev Audit regression L2: rewards smaller than one accumulator unit were silently lost
    function test_DistributeRewards_CarriesRoundingDustForward() public {
        _stake(bob, 3 ether);

        // 1 wei over 3e18 shares rounds the accumulator increment to zero
        staking.distributeRewards{value: 1}(agentA);
        assertEq(staking.getPool(agentA).accRewardPerShare, 0);
        staking.distributeRewards{value: 1}(agentA);
        staking.distributeRewards{value: 1}(agentA);

        assertEq(staking.getPool(agentA).accRewardPerShare, 1);
        assertEq(_getStake(agentA, bob).pendingRewards, 3);
    }
}
