// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVeroraConsumer
 * @author Berke (pzzaworks)
 * @notice Callback interface for contracts that request Verora queries
 * @dev QueryConsumer calls these with a bounded gas limit and ignores reverts, so a consumer can never
 *      block settlement
 */
interface IVeroraConsumer {
    /**
     * @notice Delivers the result of a completed query
     * @param requestId The query ID
     * @param result The aggregated result (empty when closed by permissionless expiry)
     */
    function onQueryFulfilled(bytes32 requestId, bytes calldata result) external;

    /**
     * @notice Signals that a query failed and its payment was refunded to the requester
     * @param requestId The query ID
     */
    function onQueryFailed(bytes32 requestId) external;
}
