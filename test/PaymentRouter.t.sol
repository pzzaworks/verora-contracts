// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IntegrationBase} from "./integration/Base.t.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";

/// @dev Treasury stand-in that rejects ETH, used to exercise the credit fallback
contract RejectingTreasury {}

contract PaymentRouterTest is IntegrationBase {
    bytes32 internal agentA;
    bytes32 internal queryId = keccak256("query");

    function setUp() public override {
        super.setUp();
        agentA = _registerAgent(alice, ENDPOINT_ALICE);
        vm.deal(address(query), 100 ether);
    }

    function _pay(uint256 amount) internal {
        vm.prank(address(query));
        payment.processPayment{value: amount}(queryId, agentA);
    }

    /// @dev Audit regression H1: anyone could pre-pay a (query, agent) pair and brick finalization
    function test_ProcessPayment_OnlyQueryConsumer() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PaymentRouter.NotQueryConsumer.selector, attacker));
        payment.processPayment{value: 1}(queryId, agentA);
    }

    function test_ProcessPayment_RevertsOnDoublePaymentAndZero() public {
        _pay(1 ether);

        vm.prank(address(query));
        vm.expectRevert(abi.encodeWithSelector(PaymentRouter.QueryAlreadyPaid.selector, queryId, agentA));
        payment.processPayment{value: 1 ether}(queryId, agentA);

        vm.prank(address(query));
        vm.expectRevert(PaymentRouter.ZeroAmount.selector);
        payment.processPayment{value: 0}(keccak256("other"), agentA);
    }

    /// @dev Audit regression H3: the platform share used to be stranded in the router
    function test_ProcessPayment_PushesPlatformFeeToTreasury() public {
        vm.prank(bob);
        staking.stake{value: 1 ether}(agentA);

        _pay(1 ether);

        assertEq(address(treasury).balance, 0.1 ether);
        assertEq(payment.getPendingFees(alice), 0.8 ether);
        assertEq(_getStake(agentA, bob).pendingRewards, 0.1 ether);
        assertEq(address(payment).balance, 0.8 ether);

        IPaymentRouter.PaymentInfo memory info = payment.getPaymentInfo(queryId, agentA);
        assertEq(info.payee, alice);
        assertTrue(info.processed);
    }

    function test_ProcessPayment_StakerShareGoesToTreasuryWithoutStakers() public {
        _pay(1 ether);
        assertEq(address(treasury).balance, 0.2 ether);
    }

    function test_ProcessPayment_PaysSuspendedAgent() public {
        vm.prank(alice);
        registry.suspendAgent(agentA, "paused");

        _pay(1 ether);
        assertEq(payment.getPendingFees(alice), 0.8 ether);
    }

    function test_WithdrawFees() public {
        _pay(1 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        payment.withdrawFees();
        assertEq(alice.balance, before + 0.8 ether);

        vm.prank(alice);
        vm.expectRevert(PaymentRouter.NothingToWithdraw.selector);
        payment.withdrawFees();
    }

    function test_TreasuryFailure_IsCreditedAndFlushable() public {
        RejectingTreasury rejecting = new RejectingTreasury();
        vm.prank(deployer);
        payment.setTreasury(address(rejecting));

        _pay(1 ether);
        // Platform share is credited; the staker share (no stakers) already went to the treasury via the pool
        assertEq(payment.pendingTreasuryFees(), 0.1 ether);

        vm.prank(deployer);
        payment.setTreasury(address(treasury));
        payment.flushTreasuryFees();

        assertEq(payment.pendingTreasuryFees(), 0);
        assertEq(address(treasury).balance, 0.2 ether);
    }

    function test_SetFeeSplit_EnforcesBounds() public {
        vm.startPrank(deployer);
        vm.expectRevert(PaymentRouter.InvalidFeeSplit.selector);
        payment.setFeeSplit(1000, 8000, 999);
        vm.expectRevert(PaymentRouter.InvalidFeeSplit.selector);
        payment.setFeeSplit(10_000, 0, 0);
        vm.expectRevert(PaymentRouter.InvalidFeeSplit.selector);
        payment.setFeeSplit(1000, 5000, 4000);

        payment.setFeeSplit(2000, 5000, 3000);
        vm.stopPrank();

        IPaymentRouter.FeeSplit memory split = payment.getFeeSplit();
        assertEq(split.platformFee, 2000);
        assertEq(split.agentFee, 5000);
        assertEq(split.stakerFee, 3000);
    }

    function test_Admin_RejectsZeroAddresses() public {
        vm.startPrank(deployer);
        vm.expectRevert(PaymentRouter.ZeroAddress.selector);
        payment.setQueryConsumer(address(0));
        vm.expectRevert(PaymentRouter.ZeroAddress.selector);
        payment.setTreasury(address(0));
        vm.expectRevert(PaymentRouter.ZeroAddress.selector);
        payment.setStakingPool(address(0));
        vm.stopPrank();
    }
}
