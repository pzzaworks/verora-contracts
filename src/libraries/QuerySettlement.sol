// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title QuerySettlement
 * @author Berke (pzzaworks)
 * @notice Settle Verora queries into payments, reputation, refunds, and consumer callbacks
 * @dev Externally linked library executed via DELEGATECALL in the QueryConsumer's storage and balance
 *      context, which keeps the QueryConsumer bytecode under the per-transaction creation gas cap.
 *      Reputation rules:
 *      - Non-responders get a failure only after the deadline, and only if the query window was at least
 *        the current minimum query duration. Finalizing early leaves them neutral.
 *      - Successes are only granted for finalizer-accepted responses, never when the requester owns the agent.
 *      - Responses the finalizer rejects are not paid and get a failure.
 *      - The permissionless expiry path pays every responder but grants no success, and only opens for
 *        queries with responses after the finalizer's grace period.
 */
import {IQueryConsumer} from "../interfaces/IQueryConsumer.sol";
import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";
import {IReputationManager} from "../interfaces/IReputationManager.sol";
import {IPaymentRouter} from "../interfaces/IPaymentRouter.sol";
import {IVeroraConsumer} from "../interfaces/IVeroraConsumer.sol";

library QuerySettlement {
    /// @notice Minimum accepted responses for a query to complete
    uint256 internal constant MIN_RESPONSES = 1;

    /// @notice Time after the deadline reserved for the finalizer before anyone can close a query with responses
    uint256 internal constant FINALIZATION_GRACE_PERIOD = 1 hours;

    /// @notice Callback revert data copied into `CallbackFailed` (longer reasons are truncated)
    uint256 internal constant MAX_CALLBACK_REASON_LENGTH = 256;

    /// @notice Gas forwarded with pushed refunds; a failed push is credited for withdrawal
    uint256 internal constant REFUND_GAS_LIMIT = 30_000;

    /// @notice Contracts and parameters a settlement needs from the QueryConsumer
    struct Context {
        bytes32 queryId;
        IAgentRegistry agentRegistry;
        IReputationManager reputationManager;
        IPaymentRouter paymentRouter;
        uint256 minQueryDuration;
        uint256 callbackGasLimit;
    }

    /**
     * @notice Settles a query with the responders the finalizer accepted
     * @dev With no accepted responders the query fails and the requester is refunded
     * @param ctx Settlement context
     * @param query The query being finalized
     * @param responses The query's responses
     * @param hasResponded Whether each agent responded to this query
     * @param pendingLists Pending query IDs per agent
     * @param positions 1-based position of each query in each agent's pending list
     * @param pendingRefunds Refund credits per requester
     * @param aggregatedResults Aggregated results per query
     * @param aggregatedResult The aggregated result
     * @param acceptedAgents Responders the finalizer accepted (unique, each must have responded)
     */
    function finalize(
        Context memory ctx,
        IQueryConsumer.QueryInfo storage query,
        IQueryConsumer.ResponseInfo[] storage responses,
        mapping(bytes32 => bool) storage hasResponded,
        mapping(bytes32 => bytes32[]) storage pendingLists,
        mapping(bytes32 => mapping(bytes32 => uint256)) storage positions,
        mapping(address => uint256) storage pendingRefunds,
        mapping(bytes32 => bytes) storage aggregatedResults,
        bytes calldata aggregatedResult,
        bytes32[] calldata acceptedAgents
    ) external {
        if (query.status != IQueryConsumer.QueryStatus.InProgress) {
            revert IQueryConsumer.QueryNotInProgress(ctx.queryId);
        }

        _markAccepted(ctx.queryId, acceptedAgents, responses, hasResponded);

        bool completed = acceptedAgents.length >= MIN_RESPONSES;
        // With every response rejected nothing usable was delivered, so the requester gets the escrow back
        query.status = completed ? IQueryConsumer.QueryStatus.Completed : IQueryConsumer.QueryStatus.Failed;
        if (completed) aggregatedResults[ctx.queryId] = aggregatedResult;

        _settle(ctx, query, responses, hasResponded, pendingLists, positions, true);
        _close(ctx, query, completed ? aggregatedResult : bytes(""), pendingRefunds);
    }

    /**
     * @notice Closes a query after its deadline. Without responses the requester is refunded; with responses
     *         (after the grace period) every responder is paid without gaining reputation.
     * @param ctx Settlement context
     * @param query The expired query
     * @param responses The query's responses
     * @param hasResponded Whether each agent responded to this query
     * @param pendingLists Pending query IDs per agent
     * @param positions 1-based position of each query in each agent's pending list
     * @param pendingRefunds Refund credits per requester
     */
    function expire(
        Context memory ctx,
        IQueryConsumer.QueryInfo storage query,
        IQueryConsumer.ResponseInfo[] storage responses,
        mapping(bytes32 => bool) storage hasResponded,
        mapping(bytes32 => bytes32[]) storage pendingLists,
        mapping(bytes32 => mapping(bytes32 => uint256)) storage positions,
        mapping(address => uint256) storage pendingRefunds
    ) external {
        bytes32 queryId = ctx.queryId;
        if (block.timestamp <= query.deadline) revert IQueryConsumer.QueryNotExpired(queryId);
        if (query.status != IQueryConsumer.QueryStatus.Pending && query.status != IQueryConsumer.QueryStatus.InProgress)
        {
            revert IQueryConsumer.QueryNotPending(queryId);
        }

        if (responses.length > 0) {
            // Responses still await validation: the finalizer keeps priority during the grace period
            uint256 opensAt = query.deadline + FINALIZATION_GRACE_PERIOD;
            if (block.timestamp <= opensAt) revert IQueryConsumer.FinalizationWindowOpen(queryId, opensAt);
            query.status = IQueryConsumer.QueryStatus.Completed;
        } else {
            query.status = IQueryConsumer.QueryStatus.Failed;
        }

        _settle(ctx, query, responses, hasResponded, pendingLists, positions, false);
        _close(ctx, query, "", pendingRefunds);
    }

    /**
     * @notice Cancels a query without responses on behalf of its requester and refunds it
     * @param queryId The query to cancel
     * @param query The query
     * @param pendingLists Pending query IDs per agent
     * @param positions 1-based position of each query in each agent's pending list
     * @param pendingRefunds Refund credits per requester
     */
    function cancel(
        bytes32 queryId,
        IQueryConsumer.QueryInfo storage query,
        mapping(bytes32 => bytes32[]) storage pendingLists,
        mapping(bytes32 => mapping(bytes32 => uint256)) storage positions,
        mapping(address => uint256) storage pendingRefunds
    ) external {
        if (query.requester != msg.sender) revert IQueryConsumer.NotQueryRequester(queryId);
        if (query.status != IQueryConsumer.QueryStatus.Pending) revert IQueryConsumer.QueryNotPending(queryId);

        query.status = IQueryConsumer.QueryStatus.Failed;
        _cleanupPendingQueries(queryId, query.assignedAgents, pendingLists, positions);

        emit IQueryConsumer.QueryCancelled(queryId, msg.sender);

        _refund(query.requester, query.payment, pendingRefunds);
    }

    /// @dev Validates the finalizer's accepted set (unique responders) and flags those responses as validated
    function _markAccepted(
        bytes32 queryId,
        bytes32[] calldata acceptedAgents,
        IQueryConsumer.ResponseInfo[] storage responses,
        mapping(bytes32 => bool) storage hasResponded
    ) private {
        uint256 acceptedCount = acceptedAgents.length;
        for (uint256 i = 0; i < acceptedCount; i++) {
            bytes32 agentId = acceptedAgents[i];
            if (!hasResponded[agentId]) revert IQueryConsumer.AgentDidNotRespond(queryId, agentId);
            for (uint256 j = 0; j < i; j++) {
                if (acceptedAgents[j] == agentId) revert IQueryConsumer.DuplicateAgent(agentId);
            }
        }

        for (uint256 i = 0; i < responses.length; i++) {
            for (uint256 j = 0; j < acceptedCount; j++) {
                if (responses[i].agentId == acceptedAgents[j]) {
                    responses[i].validated = true;
                    break;
                }
            }
        }
    }

    /**
     * @dev Pays responders an equal share (the last one also receives the rounding remainder), records
     *      reputation, and clears pending lists. With `finalizerValidated` only validated responses are paid
     *      and earn a success, the rest get a failure. Without it every responder is paid and no success is
     *      recorded.
     */
    function _settle(
        Context memory ctx,
        IQueryConsumer.QueryInfo storage query,
        IQueryConsumer.ResponseInfo[] storage responses,
        mapping(bytes32 => bool) storage hasResponded,
        mapping(bytes32 => bytes32[]) storage pendingLists,
        mapping(bytes32 => mapping(bytes32 => uint256)) storage positions,
        bool finalizerValidated
    ) private {
        _recordNonResponders(ctx, query, hasResponded);
        _cleanupPendingQueries(ctx.queryId, query.assignedAgents, pendingLists, positions);

        uint256 responseCount = responses.length;
        uint256 payeeCount;
        for (uint256 i = 0; i < responseCount; i++) {
            if (!finalizerValidated || responses[i].validated) payeeCount++;
            else ctx.reputationManager.recordFailure(responses[i].agentId, ctx.queryId);
        }
        if (payeeCount == 0) return;

        uint256 share = query.payment / payeeCount;
        uint256 remainder = query.payment - share * payeeCount;
        uint256 paid;
        for (uint256 i = 0; i < responseCount; i++) {
            IQueryConsumer.ResponseInfo storage response = responses[i];
            if (finalizerValidated && !response.validated) continue;

            bytes32 agentId = response.agentId;
            if (finalizerValidated && ctx.agentRegistry.getAgent(agentId).owner != query.requester) {
                ctx.reputationManager.recordSuccess(agentId, ctx.queryId);
            }

            uint256 amount = ++paid == payeeCount ? share + remainder : share;
            if (amount > 0) ctx.paymentRouter.processPayment{value: amount}(ctx.queryId, agentId);
        }
    }

    /// @dev Records failures for assigned agents that never answered, but only once their fair window is over
    function _recordNonResponders(
        Context memory ctx,
        IQueryConsumer.QueryInfo storage query,
        mapping(bytes32 => bool) storage hasResponded
    ) private {
        if (block.timestamp <= query.deadline || query.deadline - query.createdAt < ctx.minQueryDuration) return;

        bytes32[] storage agents = query.assignedAgents;
        for (uint256 i = 0; i < agents.length; i++) {
            if (!hasResponded[agents[i]]) ctx.reputationManager.recordFailure(agents[i], ctx.queryId);
        }
    }

    /// @dev Emits the terminal event, refunds failed queries, and notifies consumer contracts
    function _close(
        Context memory ctx,
        IQueryConsumer.QueryInfo storage query,
        bytes memory result,
        mapping(address => uint256) storage pendingRefunds
    ) private {
        bytes32 queryId = ctx.queryId;
        address requester = query.requester;

        if (query.status == IQueryConsumer.QueryStatus.Completed) {
            emit IQueryConsumer.QueryFinalized(queryId, IQueryConsumer.QueryStatus.Completed, result);
            _attemptCallback(
                queryId,
                requester,
                abi.encodeCall(IVeroraConsumer.onQueryFulfilled, (queryId, result)),
                ctx.callbackGasLimit
            );
        } else {
            emit IQueryConsumer.QueryFinalized(queryId, IQueryConsumer.QueryStatus.Failed, "");
            // Refund before the callback so a consumer can account for the returned ETH inside it
            _refund(requester, query.payment, pendingRefunds);
            _attemptCallback(
                queryId, requester, abi.encodeCall(IVeroraConsumer.onQueryFailed, (queryId)), ctx.callbackGasLimit
            );
        }
    }

    /// @dev Pushes a refund with capped gas; falls back to a withdrawable credit if the push fails
    function _refund(address requester, uint256 amount, mapping(address => uint256) storage pendingRefunds) private {
        bool success;
        assembly ("memory-safe") {
            success := call(REFUND_GAS_LIMIT, requester, amount, 0, 0, 0, 0)
        }
        if (!success) {
            pendingRefunds[requester] += amount;
            emit IQueryConsumer.RefundCredited(requester, amount);
        }
    }

    /// @dev O(1) removal per agent using stored 1-based positions
    function _cleanupPendingQueries(
        bytes32 queryId,
        bytes32[] storage agents,
        mapping(bytes32 => bytes32[]) storage pendingLists,
        mapping(bytes32 => mapping(bytes32 => uint256)) storage positions
    ) private {
        for (uint256 i = 0; i < agents.length; i++) {
            bytes32 agentId = agents[i];
            uint256 position = positions[agentId][queryId];
            if (position == 0) continue;

            bytes32[] storage pending = pendingLists[agentId];
            uint256 lastIndex = pending.length - 1;
            if (position - 1 != lastIndex) {
                bytes32 moved = pending[lastIndex];
                pending[position - 1] = moved;
                positions[agentId][moved] = position;
            }
            pending.pop();
            delete positions[agentId][queryId];
        }
    }

    /**
     * @dev Calls back consumer contracts. Requires enough gas left so a caller can't starve the callback
     *      via the 63/64 rule and still settle the query. Only `MAX_CALLBACK_REASON_LENGTH` bytes of revert
     *      data are copied, so a consumer can't burn the caller's gas with a returndata bomb.
     */
    function _attemptCallback(bytes32 queryId, address consumer, bytes memory payload, uint256 gasLimit) private {
        if (consumer.code.length == 0) return;

        if (gasleft() < (gasLimit * 64) / 63 + 10_000) revert IQueryConsumer.InsufficientGasForCallback();

        bool success;
        bytes memory reason = new bytes(MAX_CALLBACK_REASON_LENGTH);
        assembly ("memory-safe") {
            success := call(gasLimit, consumer, 0, add(payload, 0x20), mload(payload), 0, 0)
            let size := returndatasize()
            if gt(size, MAX_CALLBACK_REASON_LENGTH) { size := MAX_CALLBACK_REASON_LENGTH }
            mstore(reason, size)
            returndatacopy(add(reason, 0x20), 0, size)
        }

        if (success) emit IQueryConsumer.CallbackExecuted(queryId, consumer, true);
        else emit IQueryConsumer.CallbackFailed(queryId, consumer, reason);
    }
}
