// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IntegrationBase} from "./integration/Base.t.sol";
import {QueryConsumer} from "../src/QueryConsumer.sol";
import {IQueryConsumer} from "../src/interfaces/IQueryConsumer.sol";
import {Vm} from "forge-std/Vm.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockVeroraConsumer, RevertingConsumer, ReturndataBombConsumer} from "./mocks/MockVeroraConsumer.sol";

/// @dev Requester contract that can't receive ETH, used to exercise the refund credit path
contract NonPayableRequester {
    function create(QueryConsumer consumer, bytes32[] calldata agents, uint256 deadline)
        external
        payable
        returns (bytes32)
    {
        return consumer.createQuery{value: msg.value}("plaintext", "q", deadline, agents);
    }

    function cancel(QueryConsumer consumer, bytes32 queryId) external {
        consumer.cancelQuery(queryId);
    }

    function withdraw(QueryConsumer consumer) external {
        consumer.withdrawRefund();
    }
}

/// @dev Requester whose receive burns all forwarded gas until told to stop
contract GasGuzzlingRequester {
    bool public guzzle = true;

    function create(QueryConsumer consumer, bytes32[] calldata agents, uint256 deadline)
        external
        payable
        returns (bytes32)
    {
        return consumer.createQuery{value: msg.value}("plaintext", "q", deadline, agents);
    }

    function cancel(QueryConsumer consumer, bytes32 queryId) external {
        consumer.cancelQuery(queryId);
    }

    function withdraw(QueryConsumer consumer) external {
        guzzle = false;
        consumer.withdrawRefund();
    }

    receive() external payable {
        if (!guzzle) return;
        uint256 counter;
        while (gasleft() > 0) counter++;
    }
}

contract QueryConsumerTest is IntegrationBase {
    bytes32 internal agentA;
    bytes32 internal agentB;

    function setUp() public override {
        super.setUp();
        agentA = _registerAgent(alice, ENDPOINT_ALICE);
        agentB = _registerAgent(bob, ENDPOINT_BOB);
    }

    function _agents2() internal view returns (bytes32[] memory agents) {
        agents = new bytes32[](2);
        agents[0] = agentA;
        agents[1] = agentB;
    }

    /*//////////////////////////////////////////////////////////////
                              CREATE QUERY
    //////////////////////////////////////////////////////////////*/

    function test_CreateQuery_StoresQueryAndPendingLists() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);

        IQueryConsumer.QueryInfo memory info = query.getQuery(queryId);
        assertEq(info.requester, requester);
        assertEq(info.payment, 1 ether);
        assertEq(uint8(info.status), uint8(IQueryConsumer.QueryStatus.Pending));
        assertEq(info.assignedAgents.length, 2);
        assertEq(query.getPendingQueriesForAgent(agentA, 0, 100)[0], queryId);
        assertEq(query.getQueriesByRequester(requester)[0], queryId);
        assertEq(address(query).balance, 1 ether);
    }

    function test_CreateQuery_RevertsOnInvalidInput() public {
        bytes32[] memory none = new bytes32[](0);
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.InvalidAgentCount.selector, 0));
        query.createQuery{value: 1 ether}("t", "q", block.timestamp + 1 hours, none);

        bytes32[] memory tooMany = new bytes32[](11);
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.InvalidAgentCount.selector, 11));
        query.createQuery{value: 1 ether}("t", "q", block.timestamp + 1 hours, tooMany);

        bytes32[] memory dup = new bytes32[](2);
        dup[0] = agentA;
        dup[1] = agentA;
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.DuplicateAgent.selector, agentA));
        query.createQuery{value: 1 ether}("t", "q", block.timestamp + 1 hours, dup);

        vm.prank(requester);
        vm.expectRevert(IQueryConsumer.InvalidDeadline.selector);
        query.createQuery{value: 1 ether}("t", "q", block.timestamp, _agents2());

        vm.prank(requester);
        vm.expectRevert(IQueryConsumer.InvalidDeadline.selector);
        query.createQuery{value: 1 ether}("t", "q", block.timestamp + 31 days, _agents2());

        vm.prank(requester);
        vm.expectRevert(IQueryConsumer.PayloadTooLarge.selector);
        query.createQuery{value: 1 ether}("t", new bytes(16_385), block.timestamp + 1 hours, _agents2());
    }

    function test_CreateQuery_RequiresMinimumPaymentPerAgent() public {
        uint256 required = MIN_PAYMENT_PER_AGENT * 2;
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.InsufficientPayment.selector, required, required - 1));
        query.createQuery{value: required - 1}("t", "q", block.timestamp + 1 hours, _agents2());
    }

    function test_CreateQuery_RevertsForInactiveAgent() public {
        vm.prank(alice);
        registry.suspendAgent(agentA, "maintenance");

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.AgentNotActive.selector, agentA));
        query.createQuery{value: 1 ether}("t", "q", block.timestamp + 1 hours, _agents2());
    }

    function test_CreateQuery_RevertsWhenPaused() public {
        vm.prank(deployer);
        query.pause();

        vm.prank(requester);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        query.createQuery{value: 1 ether}("t", "q", block.timestamp + 1 hours, _agents2());
    }

    /*//////////////////////////////////////////////////////////////
                               RESPONSES
    //////////////////////////////////////////////////////////////*/

    function test_SubmitResponse_ByOwner() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 100);

        assertEq(query.getResponses(queryId).length, 1);
        assertEq(uint8(query.getQuery(queryId).status), uint8(IQueryConsumer.QueryStatus.InProgress));
    }

    function test_SubmitResponse_RevertsForNonOwnerDuplicateAndLate() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.NotAgentOwner.selector, agentA, bob));
        query.submitResponse(queryId, agentA, "x");

        _submitResponse(alice, queryId, agentA, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.AlreadyResponded.selector, queryId, agentA));
        query.submitResponse(queryId, agentA, "x");

        vm.warp(block.timestamp + 2 hours);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.QueryExpired.selector, queryId));
        query.submitResponse(queryId, agentB, "x");
    }

    function test_SubmitResponse_RevertsForUnassignedAgent() public {
        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.NotAssignedAgent.selector, queryId, agentB));
        query.submitResponse(queryId, agentB, "x");
    }

    function test_SubmitResponseFor_RelaysSignedResponse() public {
        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);
        bytes memory data = abi.encode(uint256(42));
        bytes memory signature = _signResponse(aliceKey, queryId, agentA, data);

        vm.prank(finalizer);
        query.submitResponseFor(queryId, agentA, data, signature);

        IQueryConsumer.ResponseInfo[] memory responses = query.getResponses(queryId);
        assertEq(responses.length, 1);
        assertEq(responses[0].responseData, data);
    }

    function test_SubmitResponseFor_RejectsWrongSignerOrTamperedData() public {
        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);
        bytes memory data = abi.encode(uint256(42));

        bytes memory bobSignature = _signResponse(bobKey, queryId, agentA, data);
        vm.expectRevert(IQueryConsumer.InvalidSignature.selector);
        query.submitResponseFor(queryId, agentA, data, bobSignature);

        bytes memory aliceSignature = _signResponse(aliceKey, queryId, agentA, data);
        vm.expectRevert(IQueryConsumer.InvalidSignature.selector);
        query.submitResponseFor(queryId, agentA, abi.encode(uint256(43)), aliceSignature);
    }

    /*//////////////////////////////////////////////////////////////
                              FINALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_Finalize_PaysRespondersAndRecordsNonResponders() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 100);
        vm.warp(block.timestamp + 1 hours + 1);
        _finalizeQuery(queryId, 100);

        assertEq(uint8(query.getQuery(queryId).status), uint8(IQueryConsumer.QueryStatus.Completed));
        assertEq(address(query).balance, 0);
        assertEq(payment.getPendingFees(alice), 0.8 ether);
        assertEq(_getQueryStats(agentA).successfulQueries, 1);
        assertEq(_getQueryStats(agentB).failedQueries, 1);
        assertEq(query.getPendingQueriesForAgent(agentA, 0, 100).length, 0);
        assertEq(query.getPendingQueriesForAgent(agentB, 0, 100).length, 0);
    }

    function test_Finalize_RevertsForUnauthorizedOrWrongState() public {
        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);

        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.QueryNotInProgress.selector, queryId));
        query.finalizeQuery(queryId, "", new bytes32[](0));

        _submitResponse(alice, queryId, agentA, 1);
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.NotAuthorizedFinalizer.selector, requester));
        query.finalizeQuery(queryId, "", new bytes32[](0));
    }

    /// @dev Audit regression: integer-division dust used to stay in the contract
    function test_Finalize_DistributesRoundingRemainder() public {
        bytes32 agentC = _registerAgent(charlie, ENDPOINT_CHARLIE);
        bytes32[] memory agents = new bytes32[](3);
        agents[0] = agentA;
        agents[1] = agentB;
        agents[2] = agentC;

        bytes32 queryId = _createQuery(requester, agents, 1 ether + 1, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 1);
        _submitResponse(bob, queryId, agentB, 1);
        _submitResponse(charlie, queryId, agentC, 1);
        _finalizeQuery(queryId, 1);

        assertEq(address(query).balance, 0);
        assertEq(
            address(payment).balance,
            payment.getPendingFees(alice) + payment.getPendingFees(bob) + payment.getPendingFees(charlie)
        );
    }

    /// @dev Audit regression H2: an assigned agent suspending itself used to lock the escrow
    function test_Finalize_WorksAfterAgentSuspendsItself() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 1);
        _submitResponse(bob, queryId, agentB, 1);

        vm.prank(bob);
        registry.suspendAgent(agentB, "griefing");

        _finalizeQuery(queryId, 1);
        assertEq(address(query).balance, 0);
        assertGt(payment.getPendingFees(bob), 0);
    }

    function test_FailExpired_WorksAfterNonResponderSuspends() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);
        vm.prank(bob);
        registry.suspendAgent(agentB, "griefing");

        uint256 before = requester.balance;
        vm.warp(block.timestamp + 2 hours);
        query.failExpiredQuery(queryId);

        assertEq(requester.balance, before + 1 ether);
        assertEq(_getQueryStats(agentB).failedQueries, 1);
    }

    /*//////////////////////////////////////////////////////////////
                           EXPIRY / CANCEL
    //////////////////////////////////////////////////////////////*/

    function test_FailExpired_IsPermissionlessAndRefunds() public {
        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.QueryNotExpired.selector, queryId));
        query.failExpiredQuery(queryId);

        uint256 before = requester.balance;
        vm.warp(block.timestamp + 2 hours);
        vm.prank(makeAddr("anyone"));
        query.failExpiredQuery(queryId);

        assertEq(requester.balance, before + 1 ether);
        assertEq(uint8(query.getQuery(queryId).status), uint8(IQueryConsumer.QueryStatus.Failed));
        assertEq(query.getPendingQueriesForAgent(agentA, 0, 100).length, 0);
    }

    function test_FailExpired_PaysPartialResponders() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 1);

        vm.warp(block.timestamp + 1 hours + query.FINALIZATION_GRACE_PERIOD() + 1);
        query.failExpiredQuery(queryId);

        assertEq(uint8(query.getQuery(queryId).status), uint8(IQueryConsumer.QueryStatus.Completed));
        assertEq(payment.getPendingFees(alice), 0.8 ether);
        assertEq(_getQueryStats(agentB).failedQueries, 1);
        // Unvalidated responses earn no reputation on the permissionless path
        assertEq(_getQueryStats(agentA).totalQueries, 0);
        assertFalse(query.getResponses(queryId)[0].validated);
    }

    function test_Cancel_RefundsOnlyBeforeResponses() public {
        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.NotQueryRequester.selector, queryId));
        query.cancelQuery(queryId);

        uint256 before = requester.balance;
        vm.prank(requester);
        query.cancelQuery(queryId);
        assertEq(requester.balance, before + 1 ether);

        bytes32 second = _createSingleAgentQuery(requester, agentA, 1 ether);
        _submitResponse(alice, second, agentA, 1);
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.QueryNotPending.selector, second));
        query.cancelQuery(second);
    }

    function test_Refund_FallsBackToCreditForNonPayableRequester() public {
        NonPayableRequester requesterContract = new NonPayableRequester();
        vm.deal(address(requesterContract), 0);
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentA;

        bytes32 queryId = requesterContract.create{value: 1 ether}(query, agents, block.timestamp + 1 hours);
        requesterContract.cancel(query, queryId);

        assertEq(query.getPendingRefund(address(requesterContract)), 1 ether);
        vm.expectRevert(IQueryConsumer.TransferFailed.selector);
        requesterContract.withdraw(query);
    }

    function test_PendingList_RemovalKeepsOtherQueries() public {
        bytes32 q1 = _createSingleAgentQuery(requester, agentA, 1 ether);
        bytes32 q2 = _createSingleAgentQuery(requester, agentA, 1 ether);
        bytes32 q3 = _createSingleAgentQuery(requester, agentA, 1 ether);

        vm.prank(requester);
        query.cancelQuery(q1);

        bytes32[] memory pending = query.getPendingQueriesForAgent(agentA, 0, 100);
        assertEq(pending.length, 2);
        assertTrue((pending[0] == q2 && pending[1] == q3) || (pending[0] == q3 && pending[1] == q2));

        vm.prank(requester);
        query.cancelQuery(q3);
        pending = query.getPendingQueriesForAgent(agentA, 0, 100);
        assertEq(pending.length, 1);
        assertEq(pending[0], q2);
    }

    /*//////////////////////////////////////////////////////////////
                               CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function test_Callback_DeliversResultToConsumer() public {
        MockVeroraConsumer consumer = new MockVeroraConsumer(address(query));
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentA;
        bytes32 queryId = consumer.makeRequest{value: 1 ether}("t", "q", block.timestamp + 1 hours, agents);

        _submitResponse(alice, queryId, agentA, 7);
        _finalizeQuery(queryId, 7);

        assertEq(consumer.lastRequestId(), queryId);
        assertEq(consumer.lastResult(), abi.encode(uint256(7)));
    }

    function test_Callback_RevertingConsumerDoesNotBlockFinalization() public {
        RevertingConsumer consumer = new RevertingConsumer(address(query));
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentA;
        bytes32 queryId = consumer.makeRequest{value: 1 ether}("t", "q", block.timestamp + 1 hours, agents);

        _submitResponse(alice, queryId, agentA, 7);
        _finalizeQuery(queryId, 7);
        assertEq(uint8(query.getQuery(queryId).status), uint8(IQueryConsumer.QueryStatus.Completed));
    }

    /// @dev Audit regression: callers could starve the callback via the 63/64 rule
    function test_Callback_RevertsWhenGasIsTooLowForCallback() public {
        vm.prank(deployer);
        query.setCallbackGasLimit(2_000_000);
        MockVeroraConsumer consumer = new MockVeroraConsumer(address(query));
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentA;
        bytes32 queryId = consumer.makeRequest{value: 1 ether}("t", "q", block.timestamp + 1 hours, agents);
        _submitResponse(alice, queryId, agentA, 7);
        bytes32[] memory accepted = _responders(queryId);

        vm.prank(finalizer);
        vm.expectRevert(IQueryConsumer.InsufficientGasForCallback.selector);
        query.finalizeQuery{gas: 1_500_000}(queryId, abi.encode(uint256(7)), accepted);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_Admin_CallbackGasLimitIsBounded() public {
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.InvalidCallbackGasLimit.selector, 0));
        query.setCallbackGasLimit(0);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.InvalidCallbackGasLimit.selector, 2_000_001));
        query.setCallbackGasLimit(2_000_001);
        query.setCallbackGasLimit(300_000);
        vm.stopPrank();
        assertEq(query.callbackGasLimit(), 300_000);
    }

    function test_Admin_OwnershipTransferIsTwoStep() public {
        address newOwner = makeAddr("multisig");
        vm.prank(deployer);
        query.transferOwnership(newOwner);
        assertEq(query.owner(), deployer);

        vm.prank(newOwner);
        query.acceptOwnership();
        assertEq(query.owner(), newOwner);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        query.pause();
    }

    /*//////////////////////////////////////////////////////////////
                    REGRESSIONS: GRIEFING AND SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Audit regression H1: a deadline of now+1 let requesters record free failures for any agent
    function test_CreateQuery_EnforcesMinQueryDuration() public {
        uint256 minimum = query.minQueryDuration();
        assertEq(minimum, 5 minutes);

        vm.startPrank(requester);
        vm.expectRevert(IQueryConsumer.InvalidDeadline.selector);
        query.createQuery{value: 1 ether}("t", "q", block.timestamp + 1, _agents2());

        vm.expectRevert(IQueryConsumer.InvalidDeadline.selector);
        query.createQuery{value: 1 ether}("t", "q", block.timestamp + minimum - 1, _agents2());

        query.createQuery{value: 1 ether}("t", "q", block.timestamp + minimum, _agents2());
        vm.stopPrank();
    }

    function test_Admin_MinQueryDurationIsBoundedAndEmits() public {
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.InvalidMinQueryDuration.selector, 59));
        query.setMinQueryDuration(59);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.InvalidMinQueryDuration.selector, 1 days + 1));
        query.setMinQueryDuration(1 days + 1);

        vm.expectEmit(false, false, false, true, address(query));
        emit QueryConsumer.MinQueryDurationUpdated(5 minutes, 10 minutes);
        query.setMinQueryDuration(10 minutes);
        vm.stopPrank();
        assertEq(query.minQueryDuration(), 10 minutes);

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, requester));
        query.setMinQueryDuration(10 minutes);
    }

    /// @dev Audit regression H1: queries shorter than the current fair window never count as failures
    function test_FailExpired_NoFailureWhenWindowBelowCurrentMinimum() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 5 minutes);
        vm.prank(deployer);
        query.setMinQueryDuration(10 minutes);

        uint256 before = requester.balance;
        vm.warp(block.timestamp + 5 minutes + 1);
        query.failExpiredQuery(queryId);

        assertEq(requester.balance, before + 1 ether);
        assertEq(_getQueryStats(agentA).totalQueries, 0);
        assertEq(_getQueryStats(agentB).totalQueries, 0);
    }

    /// @dev Audit regression M1: finalizing early used to penalize agents that still had time to answer
    function test_Finalize_BeforeDeadlineLeavesNonRespondersNeutral() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 100);
        _finalizeQuery(queryId, 100);

        assertEq(_getQueryStats(agentA).successfulQueries, 1);
        assertEq(_getQueryStats(agentB).totalQueries, 0);
        assertEq(query.getPendingQueryCount(agentB), 0);
    }

    /// @dev Audit regression M1: junk responses the finalizer rejects are neither paid nor validated
    function test_Finalize_RejectedResponsesAreNotPaid() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 100);
        _submitResponse(bob, queryId, agentB, 999_999);

        bytes32[] memory accepted = new bytes32[](1);
        accepted[0] = agentA;
        vm.prank(finalizer);
        query.finalizeQuery(queryId, abi.encode(uint256(100)), accepted);

        assertEq(payment.getPendingFees(alice), 0.8 ether);
        assertEq(payment.getPendingFees(bob), 0);
        assertEq(_getQueryStats(agentA).successfulQueries, 1);
        assertEq(_getQueryStats(agentB).failedQueries, 1);

        IQueryConsumer.ResponseInfo[] memory responses = query.getResponses(queryId);
        assertTrue(responses[0].validated);
        assertFalse(responses[1].validated);
        assertEq(address(query).balance, 0);
    }

    function test_Finalize_AllRejectedFailsAndRefunds() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 100);

        uint256 before = requester.balance;
        vm.prank(finalizer);
        query.finalizeQuery(queryId, "", new bytes32[](0));

        assertEq(uint8(query.getQuery(queryId).status), uint8(IQueryConsumer.QueryStatus.Failed));
        assertEq(requester.balance, before + 1 ether);
        assertEq(payment.getPendingFees(alice), 0);
        assertEq(_getQueryStats(agentA).failedQueries, 1);
        assertEq(_getQueryStats(agentB).totalQueries, 0);
        assertEq(address(query).balance, 0);
    }

    function test_Finalize_RevertsForInvalidAcceptedSet() public {
        bytes32 queryId = _createQuery(requester, _agents2(), 1 ether, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 100);

        bytes32[] memory nonResponder = new bytes32[](1);
        nonResponder[0] = agentB;
        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.AgentDidNotRespond.selector, queryId, agentB));
        query.finalizeQuery(queryId, "", nonResponder);

        bytes32[] memory duplicate = new bytes32[](2);
        duplicate[0] = agentA;
        duplicate[1] = agentA;
        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.DuplicateAgent.selector, agentA));
        query.finalizeQuery(queryId, "", duplicate);
    }

    /// @dev Audit regression M2: requesters could farm reputation for their own agents
    function test_Finalize_SelfDealingIsPaidButEarnsNoReputation() public {
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentA;
        bytes32 queryId = _createQuery(alice, agents, 1 ether, block.timestamp + 1 hours);
        _submitResponse(alice, queryId, agentA, 1);
        _finalizeQuery(queryId, 1);

        assertEq(payment.getPendingFees(alice), 0.8 ether);
        assertEq(_getQueryStats(agentA).totalQueries, 0);
    }

    /// @dev Audit regression M2: permissionless completion used to grant reputation before the finalizer ran
    function test_FailExpired_WithResponsesWaitsForFinalizerGracePeriod() public {
        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);
        _submitResponse(alice, queryId, agentA, 1);

        uint256 opensAt = block.timestamp + 1 hours + query.FINALIZATION_GRACE_PERIOD();
        vm.warp(opensAt);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.FinalizationWindowOpen.selector, queryId, opensAt));
        query.failExpiredQuery(queryId);

        // The finalizer can still settle after the deadline during its grace period
        _finalizeQuery(queryId, 1);
        assertEq(_getQueryStats(agentA).successfulQueries, 1);
    }

    /*//////////////////////////////////////////////////////////////
                      REGRESSIONS: REQUEST-BOUND SIGNING
    //////////////////////////////////////////////////////////////*/

    function _typedDigest(bytes32 queryId, bytes32 agentId, bytes32 typeHash, bytes32 dataHash, bytes memory data)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Verora QueryConsumer"),
                keccak256("1"),
                block.chainid,
                address(query)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Response(bytes32 queryId,bytes32 agentId,bytes32 queryTypeHash,bytes32 queryDataHash,bytes32 responseHash)"
                ),
                queryId,
                agentId,
                typeHash,
                dataHash,
                keccak256(data)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function test_ResponseDigest_MatchesRequestBoundTypedData() public {
        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);
        bytes memory data = abi.encode(uint256(42));

        bytes32 expected =
            _typedDigest(queryId, agentA, keccak256("price_feed"), keccak256(abi.encode("ETH/USD")), data);
        assertEq(query.responseDigest(queryId, agentA, data), expected);

        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.QueryNotFound.selector, bytes32(uint256(1))));
        query.responseDigest(bytes32(uint256(1)), agentA, data);
    }

    /// @dev The lean ERC-5267 domain must match what wallets and the oracle sign under, on any chain
    function test_Eip712Domain_MatchesSigningDomain() public {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            query.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Verora QueryConsumer");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(query));

        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);
        bytes memory data = abi.encode(uint256(1));
        vm.chainId(11_155_111);
        bytes32 expected =
            _typedDigest(queryId, agentA, keccak256("price_feed"), keccak256(abi.encode("ETH/USD")), data);
        assertEq(query.responseDigest(queryId, agentA, data), expected);
    }

    /// @dev Audit regression: a signature obtained by sending the agent forged query data was relayable
    function test_SubmitResponseFor_RejectsSignatureOverForgedRequest() public {
        bytes32 queryId = _createSingleAgentQuery(requester, agentA, 1 ether);
        bytes memory data = abi.encode(uint256(42));

        bytes32 forgedData = _typedDigest(queryId, agentA, keccak256("price_feed"), keccak256("forged"), data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, forgedData);
        vm.expectRevert(IQueryConsumer.InvalidSignature.selector);
        query.submitResponseFor(queryId, agentA, data, abi.encodePacked(r, s, v));

        bytes32 forgedType = _typedDigest(queryId, agentA, keccak256("forged"), keccak256(abi.encode("ETH/USD")), data);
        (v, r, s) = vm.sign(aliceKey, forgedType);
        vm.expectRevert(IQueryConsumer.InvalidSignature.selector);
        query.submitResponseFor(queryId, agentA, data, abi.encodePacked(r, s, v));
    }

    /*//////////////////////////////////////////////////////////////
                   REGRESSIONS: CALLBACKS, REFUNDS, VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @dev Audit regression M3: callback revert data is truncated instead of copied in full
    function test_Callback_ReturndataBombIsTruncated() public {
        ReturndataBombConsumer consumer = new ReturndataBombConsumer(address(query));
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentA;
        bytes32 queryId = consumer.makeRequest{value: 1 ether}("t", "q", block.timestamp + 1 hours, agents);
        _submitResponse(alice, queryId, agentA, 7);

        vm.recordLogs();
        _finalizeQuery(queryId, 7);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != IQueryConsumer.CallbackFailed.selector) continue;
            bytes memory reason = abi.decode(logs[i].data, (bytes));
            assertEq(reason.length, query.MAX_CALLBACK_REASON_LENGTH());
            found = true;
        }
        assertTrue(found);
        assertEq(uint8(query.getQuery(queryId).status), uint8(IQueryConsumer.QueryStatus.Completed));
    }

    /// @dev Audit regression L3: failed queries never cleared the consumer's pending request
    function test_Callback_FailedQueryNotifiesConsumer() public {
        MockVeroraConsumer consumer = new MockVeroraConsumer(address(query));
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentA;
        bytes32 queryId = consumer.makeRequest{value: 1 ether}("t", "q", block.timestamp + 1 hours, agents);
        assertTrue(consumer.isPending(queryId));

        vm.warp(block.timestamp + 1 hours + 1);
        query.failExpiredQuery(queryId);

        assertEq(consumer.lastFailedRequestId(), queryId);
        assertFalse(consumer.isPending(queryId));
        assertEq(address(consumer).balance, 1 ether);
    }

    /// @dev Audit regression L1: refunds forwarded all gas to the requester
    function test_Refund_GasGuzzlingRequesterIsCredited() public {
        GasGuzzlingRequester guzzler = new GasGuzzlingRequester();
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentA;
        bytes32 queryId = guzzler.create{value: 1 ether}(query, agents, block.timestamp + 1 hours);

        uint256 gasBefore = gasleft();
        guzzler.cancel(query, queryId);
        assertLt(gasBefore - gasleft(), 200_000);
        assertEq(query.getPendingRefund(address(guzzler)), 1 ether);

        guzzler.withdraw(query);
        assertEq(address(guzzler).balance, 1 ether);
        assertEq(query.getPendingRefund(address(guzzler)), 0);
    }

    /// @dev Audit regression M4: the pending list could only be read in one unbounded call
    function test_PendingQueries_ArePaginated() public {
        bytes32 q1 = _createSingleAgentQuery(requester, agentA, 1 ether);
        bytes32 q2 = _createSingleAgentQuery(requester, agentA, 1 ether);
        bytes32 q3 = _createSingleAgentQuery(requester, agentA, 1 ether);

        assertEq(query.getPendingQueryCount(agentA), 3);
        bytes32[] memory page = query.getPendingQueriesForAgent(agentA, 0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], q1);
        assertEq(page[1], q2);

        page = query.getPendingQueriesForAgent(agentA, 2, type(uint256).max);
        assertEq(page.length, 1);
        assertEq(page[0], q3);

        assertEq(query.getPendingQueriesForAgent(agentA, 3, 10).length, 0);
        assertEq(query.getPendingQueriesForAgent(agentA, 0, 0).length, 0);
    }

    /// @dev Audit regression L6: pointing at a router that rejects this contract would brick settlement
    function test_Admin_SetPaymentRouterRequiresWiring() public {
        vm.startPrank(deployer);
        PaymentRouter router = new PaymentRouter(deployer, address(registry), address(staking), address(treasury));

        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.PaymentRouterMismatch.selector, address(router)));
        query.setPaymentRouter(address(router));

        router.setQueryConsumer(address(query));
        query.setPaymentRouter(address(router));
        vm.stopPrank();
        assertEq(address(query.paymentRouter()), address(router));
    }
}
