// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IQueryConsumer
 * @author Berke (pzzaworks)
 * @notice Interface for the Verora query escrow, response, and settlement contract
 * @dev Agents answer with responses signed over the query they were sent (EIP-712), the oracle finalizer
 *      validates them, and settlement pays accepted responders and records reputation
 */
interface IQueryConsumer {
    /// @notice Query status enumeration
    enum QueryStatus {
        Pending,
        InProgress,
        Completed,
        Failed
    }

    /// @notice Query information structure
    struct QueryInfo {
        bytes32 queryId;
        address requester;
        string queryType;
        bytes queryData;
        QueryStatus status;
        uint256 createdAt;
        uint256 deadline;
        uint256 payment;
        bytes32[] assignedAgents;
    }

    /// @notice Response information structure
    /// @dev `validated` is true only for responses the finalizer accepted
    struct ResponseInfo {
        bytes32 agentId;
        bytes responseData;
        uint256 submittedAt;
        bool validated;
    }

    /// @notice Emitted when a new query is created
    event QueryCreated(bytes32 indexed queryId, address indexed requester, string queryType, uint256 payment);

    /// @notice Emitted when an agent response is recorded
    event ResponseSubmitted(bytes32 indexed queryId, bytes32 indexed agentId, uint256 submittedAt);

    /// @notice Emitted when a query reaches a terminal state
    event QueryFinalized(bytes32 indexed queryId, QueryStatus status, bytes aggregatedResult);

    /// @notice Emitted when a requester cancels a query that has no responses yet
    event QueryCancelled(bytes32 indexed queryId, address indexed requester);

    /// @notice Emitted when a refund could not be pushed and was credited for later withdrawal
    event RefundCredited(address indexed requester, uint256 amount);

    /// @notice Emitted when a consumer contract callback succeeded
    event CallbackExecuted(bytes32 indexed queryId, address indexed consumer, bool success);

    /// @notice Emitted when a consumer contract callback reverted; `reason` is truncated to 256 bytes
    event CallbackFailed(bytes32 indexed queryId, address indexed consumer, bytes reason);

    /// @notice An assigned agent is not active
    error AgentNotActive(bytes32 agentId);
    /// @notice An agent appears twice in an assignment or accepted set
    error DuplicateAgent(bytes32 agentId);
    /// @notice The finalizer accepted an agent that did not respond
    error AgentDidNotRespond(bytes32 queryId, bytes32 agentId);
    /// @notice Not enough gas was forwarded to run the consumer callback with its full gas limit
    error InsufficientGasForCallback();
    error QueryNotFound(bytes32 queryId);
    error QueryNotPending(bytes32 queryId);
    error QueryNotInProgress(bytes32 queryId);
    error QueryExpired(bytes32 queryId);
    error QueryNotExpired(bytes32 queryId);
    error FinalizationWindowOpen(bytes32 queryId, uint256 opensAt);
    error NotAssignedAgent(bytes32 queryId, bytes32 agentId);
    error NotAgentOwner(bytes32 agentId, address caller);
    error InvalidSignature();
    error AlreadyResponded(bytes32 queryId, bytes32 agentId);
    error NotQueryRequester(bytes32 queryId);
    error NotAuthorizedFinalizer(address caller);
    error ZeroAddress();
    error InsufficientPayment(uint256 required, uint256 provided);
    error InvalidDeadline();
    error InvalidAgentCount(uint256 count);
    error PayloadTooLarge();
    error InvalidCallbackGasLimit(uint256 gasLimit);
    error InvalidMinQueryDuration(uint256 duration);
    error PaymentRouterMismatch(address paymentRouter);
    error NothingToWithdraw();
    error TransferFailed();

    /**
     * @notice Creates a paid query assigned to a set of agents
     * @param queryType Free-form query type (e.g. "plaintext", "encrypted")
     * @param queryData Query payload
     * @param deadline Timestamp after which no responses are accepted; at least `minQueryDuration` away
     * @param agents Assigned agent IDs (unique, active)
     * @return queryId The new query ID
     */
    function createQuery(
        string calldata queryType,
        bytes calldata queryData,
        uint256 deadline,
        bytes32[] calldata agents
    ) external payable returns (bytes32 queryId);

    /**
     * @notice Submits a response as the agent owner
     * @param queryId The query being answered
     * @param agentId The assigned agent answering
     * @param responseData The response payload
     */
    function submitResponse(bytes32 queryId, bytes32 agentId, bytes calldata responseData) external;

    /**
     * @notice Submits a response on behalf of an agent using the agent owner's EIP-712 signature
     * @dev Lets an oracle relay responses so agents do not need to pay gas. The signature covers the hashes
     *      of the stored query type and data, so a signature obtained with forged request data is rejected.
     * @param queryId The query being answered
     * @param agentId The assigned agent answering
     * @param responseData The response payload
     * @param signature Agent owner signature over `responseDigest(queryId, agentId, responseData)`
     */
    function submitResponseFor(bytes32 queryId, bytes32 agentId, bytes calldata responseData, bytes calldata signature)
        external;

    /**
     * @notice Settles a query with responses, paying only the responders the finalizer accepted
     * @dev Accepted responders split the payment and gain reputation; rejected responders are not paid and
     *      get a failure. Non-responders get a failure only once the deadline has passed. With no accepted
     *      responders the query fails and the requester is refunded.
     * @param queryId The query to settle
     * @param aggregatedResult The aggregated result delivered to the requester
     * @param acceptedAgents Responders whose answers were used (unique, each must have responded)
     */
    function finalizeQuery(bytes32 queryId, bytes calldata aggregatedResult, bytes32[] calldata acceptedAgents)
        external;

    /**
     * @notice Closes a query after its deadline. Permissionless.
     * @dev Without responses the requester is refunded right after the deadline. With responses it is only
     *      callable once the finalization grace period has passed; responders are then paid but, being
     *      unvalidated, gain no reputation.
     * @param queryId The query to close
     */
    function failExpiredQuery(bytes32 queryId) external;

    /**
     * @notice Cancels a query that has no responses yet and refunds the requester
     * @param queryId The query to cancel
     */
    function cancelQuery(bytes32 queryId) external;

    /**
     * @notice Withdraws refunds that could not be pushed to the caller
     */
    function withdrawRefund() external;

    /// @notice Returns a query by ID
    function getQuery(bytes32 queryId) external view returns (QueryInfo memory info);

    /// @notice Returns every response recorded for a query
    function getResponses(bytes32 queryId) external view returns (ResponseInfo[] memory responses);

    /// @notice Returns the aggregated result of a completed query
    function getAggregatedResult(bytes32 queryId) external view returns (bytes memory result);

    /// @notice Returns every query created by a requester
    function getQueriesByRequester(address requester) external view returns (bytes32[] memory queryIds);

    /**
     * @notice Returns a page of an agent's open queries (unordered: removals swap in the last entry)
     * @param agentId The agent
     * @param offset Index of the first entry
     * @param limit Maximum number of entries
     * @return queryIds The page of pending query IDs
     */
    function getPendingQueriesForAgent(bytes32 agentId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory queryIds);

    /// @notice Number of open queries assigned to an agent
    function getPendingQueryCount(bytes32 agentId) external view returns (uint256 count);

    /// @notice Refund credited to a requester that could not be pushed
    function getPendingRefund(address requester) external view returns (uint256 amount);

    /**
     * @notice EIP-712 digest an agent owner signs to authorize a relayed response
     * @dev Typed struct: Response(bytes32 queryId,bytes32 agentId,bytes32 queryTypeHash,bytes32
     *      queryDataHash,bytes32 responseHash), with the hashes taken from the query as stored on-chain
     */
    function responseDigest(bytes32 queryId, bytes32 agentId, bytes calldata responseData)
        external
        view
        returns (bytes32 digest);
}
