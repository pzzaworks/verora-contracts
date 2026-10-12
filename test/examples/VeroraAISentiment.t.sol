// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IntegrationBase} from "../integration/Base.t.sol";
import {VeroraAISentiment} from "../../src/examples/VeroraAISentiment.sol";

contract VeroraAISentimentTest is IntegrationBase {
    VeroraAISentiment internal sentiment;
    bytes32 internal agentId;

    function setUp() public override {
        super.setUp();
        agentId = _registerAgent(alice, ENDPOINT_ALICE);

        sentiment = new VeroraAISentiment(address(query), deployer);
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentId;
        vm.prank(deployer);
        sentiment.setDefaultAgents(agents);
    }

    function test_Fulfillment_StoresSentiment() public {
        vm.prank(requester);
        bytes32 requestId = sentiment.requestSentiment{value: 0.01 ether}("ETH");

        bytes memory result = abi.encode(int256(42), uint256(90));
        vm.prank(alice);
        query.submitResponse(requestId, agentId, result);
        bytes32[] memory accepted = _responders(requestId);
        vm.prank(finalizer);
        query.finalizeQuery(requestId, result, accepted);

        VeroraAISentiment.SentimentData memory data = sentiment.getSentiment("ETH");
        assertEq(data.score, 42);
        assertEq(data.confidence, 90);
        assertEq(data.requestId, requestId);
    }

    /// @dev Audit regression: expiry delivers an empty result, which used to make the decode revert
    function test_ExpiryWithPartialResponse_KeepsPreviousValue() public {
        vm.prank(requester);
        bytes32 requestId = sentiment.requestSentiment{value: 0.01 ether}("ETH");
        vm.prank(alice);
        query.submitResponse(requestId, agentId, "partial");

        vm.warp(block.timestamp + 1 hours + query.FINALIZATION_GRACE_PERIOD() + 1);
        vm.expectEmit(true, false, false, true, address(sentiment));
        emit VeroraAISentiment.SentimentUnavailable(requestId, "ETH");
        query.failExpiredQuery(requestId);

        assertEq(sentiment.getSentiment("ETH").updatedAt, 0);
    }

    /// @dev Audit regression: refunds used to be stuck in the consumer contract, then sweepable by the owner
    function test_CancelCreditsPayerAndOwnerCannotSweepIt() public {
        vm.prank(requester);
        bytes32 requestId = sentiment.requestSentiment{value: 0.01 ether}("ETH");

        vm.prank(deployer);
        sentiment.cancelRequest(requestId);
        assertEq(address(sentiment).balance, 0.01 ether);
        assertEq(sentiment.refunds(requester), 0.01 ether);

        address payable recipient = payable(makeAddr("recipient"));
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(VeroraAISentiment.InsufficientWithdrawable.selector, 0.01 ether, 0));
        sentiment.withdraw(recipient, 0.01 ether);

        uint256 before = requester.balance;
        vm.prank(requester);
        sentiment.withdrawRefund();
        assertEq(requester.balance, before + 0.01 ether);
        assertEq(sentiment.totalRefundsOwed(), 0);
    }

    /// @dev Audit regression L3: failed queries left the request pending and the refund unattributed
    function test_FailedQueryCreditsPayerViaFailureCallback() public {
        vm.prank(requester);
        bytes32 requestId = sentiment.requestSentiment{value: 0.01 ether}("ETH");

        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectEmit(true, true, false, true, address(sentiment));
        emit VeroraAISentiment.RefundCredited(requestId, requester, 0.01 ether);
        query.failExpiredQuery(requestId);

        assertEq(sentiment.refunds(requester), 0.01 ether);
        assertEq(address(sentiment).balance, 0.01 ether);

        // Surplus ETH that is not owed to payers stays withdrawable by the owner
        vm.deal(address(sentiment), 0.03 ether);
        address payable recipient = payable(makeAddr("recipient"));
        vm.prank(deployer);
        sentiment.withdraw(recipient, 0.02 ether);
        assertEq(recipient.balance, 0.02 ether);
    }

    function test_AllResponsesRejectedRefundsPayer() public {
        vm.prank(requester);
        bytes32 requestId = sentiment.requestSentiment{value: 0.01 ether}("ETH");
        vm.prank(alice);
        query.submitResponse(requestId, agentId, "junk");

        vm.prank(finalizer);
        query.finalizeQuery(requestId, "", new bytes32[](0));

        assertEq(sentiment.refunds(requester), 0.01 ether);
        assertEq(payment.getPendingFees(alice), 0);
    }
}
