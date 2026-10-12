// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title VeroraConsumer
 * @author Berke (pzzaworks)
 * @notice Base contract for contracts that consume Verora oracle data
 * @dev Implements request tracking with fulfillment and failure callbacks from the QueryConsumer.
 *      Inherit it and implement `_onQueryFulfilled`; override `_onQueryFailed` to react to failed queries, whose
 *      payment is refunded to this contract before the callback runs.
 */
import {IVeroraConsumer} from "./interfaces/IVeroraConsumer.sol";
import {IQueryConsumer} from "./interfaces/IQueryConsumer.sol";

abstract contract VeroraConsumer is IVeroraConsumer {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The QueryConsumer contract that fulfills requests
    IQueryConsumer public immutable queryConsumer;

    /// @notice Tracks pending request IDs originated from this contract
    mapping(bytes32 => bool) internal _pendingRequests;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyQueryConsumer();
    error RequestNotPending(bytes32 requestId);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the VeroraConsumer with the QueryConsumer address
     * @param queryConsumer_ The address of the QueryConsumer contract
     */
    constructor(address queryConsumer_) {
        queryConsumer = IQueryConsumer(queryConsumer_);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts a callback to the QueryConsumer and consumes the pending request
    modifier consumesRequest(bytes32 requestId) {
        if (msg.sender != address(queryConsumer)) revert OnlyQueryConsumer();
        if (!_pendingRequests[requestId]) revert RequestNotPending(requestId);
        _pendingRequests[requestId] = false;
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Called by QueryConsumer when a query is fulfilled
     * @dev Only callable by the QueryConsumer contract
     * @param requestId The ID of the fulfilled request
     * @param result The aggregated result data
     */
    function onQueryFulfilled(bytes32 requestId, bytes calldata result) external override consumesRequest(requestId) {
        _onQueryFulfilled(requestId, result);
    }

    /**
     * @notice Called by QueryConsumer when a query fails; the payment has already been refunded here
     * @dev Only callable by the QueryConsumer contract
     * @param requestId The ID of the failed request
     */
    function onQueryFailed(bytes32 requestId) external override consumesRequest(requestId) {
        _onQueryFailed(requestId);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sends a query request to the QueryConsumer
     * @param queryType The type of query
     * @param queryData The encoded query parameters
     * @param deadline The deadline timestamp for responses
     * @param agents The agents to assign to this query
     * @return requestId The unique identifier for the request
     */
    function _requestQuery(string memory queryType, bytes memory queryData, uint256 deadline, bytes32[] memory agents)
        internal
        returns (bytes32 requestId)
    {
        requestId = queryConsumer.createQuery{value: msg.value}(queryType, queryData, deadline, agents);
        _pendingRequests[requestId] = true;
    }

    /**
     * @notice Cancels a request that has no responses yet; the refund is sent back to this contract
     * @param requestId The request to cancel
     */
    function _cancelRequest(bytes32 requestId) internal {
        if (!_pendingRequests[requestId]) revert RequestNotPending(requestId);
        _pendingRequests[requestId] = false;
        queryConsumer.cancelQuery(requestId);
    }

    /**
     * @notice Internal callback to be implemented by consuming contracts
     * @dev Override this function to handle fulfilled query results
     * @param requestId The ID of the fulfilled request
     * @param result The aggregated result data
     */
    function _onQueryFulfilled(bytes32 requestId, bytes calldata result) internal virtual;

    /**
     * @notice Optional hook for failed requests; the pending flag is already cleared when it runs
     * @dev Override to release per-request state or credit the refunded payment
     * @param requestId The ID of the failed request
     */
    function _onQueryFailed(bytes32 requestId) internal virtual {}

    /*//////////////////////////////////////////////////////////////
                              RECEIVE
    //////////////////////////////////////////////////////////////*/

    /// @notice Receive function to accept ETH
    receive() external payable {}
}
