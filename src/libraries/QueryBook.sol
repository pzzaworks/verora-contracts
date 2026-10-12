// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title QueryBook
 * @author Berke (pzzaworks)
 * @notice Validate and record Verora queries, agent assignments, and responses
 * @dev Externally linked library executed via DELEGATECALL in the QueryConsumer's storage context, which
 *      keeps the QueryConsumer bytecode under the per-transaction creation gas cap
 */
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IQueryConsumer} from "../interfaces/IQueryConsumer.sol";
import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";

library QueryBook {
    /// @notice Upper bound on agents per query (bounds every per-query loop)
    uint256 internal constant MAX_AGENTS_PER_QUERY = 10;

    /// @notice Longest allowed query lifetime, so escrow can't be locked indefinitely
    uint256 internal constant MAX_QUERY_DURATION = 30 days;

    /// @notice Size limits for on-chain payloads
    uint256 internal constant MAX_QUERY_DATA_LENGTH = 16_384;
    uint256 internal constant MAX_RESPONSE_DATA_LENGTH = 16_384;
    uint256 internal constant MAX_QUERY_TYPE_LENGTH = 64;

    /// @notice Hashes of the request an agent signs over, computed once at creation
    struct RequestHashes {
        bytes32 queryTypeHash;
        bytes32 queryDataHash;
    }

    /// @notice Value parameters of a new query
    struct CreateConfig {
        bytes32 queryId;
        address requester;
        uint256 payment;
        IAgentRegistry agentRegistry;
        uint256 minQueryDuration;
        uint256 minPaymentPerAgent;
    }

    /**
     * @notice Validates and stores a new query, then adds it to every assigned agent's pending list
     * @param config Value parameters of the query
     * @param queries Query records
     * @param requestHashes Request hashes agents sign over
     * @param requesterQueries Query IDs per requester
     * @param isAssigned Whether each agent is assigned to this query
     * @param pendingLists Pending query IDs per agent
     * @param positions 1-based position of each query in each agent's pending list
     * @param queryType Free-form query type
     * @param queryData Query payload
     * @param deadline Response deadline, at least `minQueryDuration` away
     * @param agents Assigned agent IDs (unique, active)
     */
    function create(
        CreateConfig memory config,
        mapping(bytes32 => IQueryConsumer.QueryInfo) storage queries,
        mapping(bytes32 => RequestHashes) storage requestHashes,
        mapping(address => bytes32[]) storage requesterQueries,
        mapping(bytes32 => bool) storage isAssigned,
        mapping(bytes32 => bytes32[]) storage pendingLists,
        mapping(bytes32 => mapping(bytes32 => uint256)) storage positions,
        string calldata queryType,
        bytes calldata queryData,
        uint256 deadline,
        bytes32[] calldata agents
    ) external {
        uint256 agentCount = agents.length;
        if (agentCount == 0 || agentCount > MAX_AGENTS_PER_QUERY) revert IQueryConsumer.InvalidAgentCount(agentCount);
        if (deadline < block.timestamp + config.minQueryDuration || deadline > block.timestamp + MAX_QUERY_DURATION) {
            revert IQueryConsumer.InvalidDeadline();
        }
        if (bytes(queryType).length > MAX_QUERY_TYPE_LENGTH || queryData.length > MAX_QUERY_DATA_LENGTH) {
            revert IQueryConsumer.PayloadTooLarge();
        }
        uint256 requiredPayment = config.minPaymentPerAgent * agentCount;
        if (config.payment == 0 || config.payment < requiredPayment) {
            revert IQueryConsumer.InsufficientPayment(requiredPayment == 0 ? 1 : requiredPayment, config.payment);
        }

        bytes32 queryId = config.queryId;
        for (uint256 i = 0; i < agentCount; i++) {
            bytes32 agentId = agents[i];
            if (!config.agentRegistry.isActiveAgent(agentId)) revert IQueryConsumer.AgentNotActive(agentId);
            if (isAssigned[agentId]) revert IQueryConsumer.DuplicateAgent(agentId);
            isAssigned[agentId] = true;

            pendingLists[agentId].push(queryId);
            positions[agentId][queryId] = pendingLists[agentId].length;
        }

        IQueryConsumer.QueryInfo storage stored = queries[queryId];
        stored.queryId = queryId;
        stored.requester = config.requester;
        stored.queryType = queryType;
        stored.queryData = queryData;
        stored.status = IQueryConsumer.QueryStatus.Pending;
        stored.createdAt = block.timestamp;
        stored.deadline = deadline;
        stored.payment = config.payment;
        stored.assignedAgents = agents;

        requestHashes[queryId] =
            RequestHashes({queryTypeHash: keccak256(bytes(queryType)), queryDataHash: keccak256(queryData)});
        requesterQueries[config.requester].push(queryId);

        emit IQueryConsumer.QueryCreated(queryId, config.requester, queryType, config.payment);
    }

    /**
     * @notice Validates and records an agent response
     * @param query The query being answered
     * @param responses The query's responses
     * @param isAssigned Whether each agent is assigned to this query
     * @param hasResponded Whether each agent responded to this query
     * @param queryId The query ID
     * @param agentId The responding agent
     * @param responseData The response payload
     */
    function recordResponse(
        IQueryConsumer.QueryInfo storage query,
        IQueryConsumer.ResponseInfo[] storage responses,
        mapping(bytes32 => bool) storage isAssigned,
        mapping(bytes32 => bool) storage hasResponded,
        bytes32 queryId,
        bytes32 agentId,
        bytes calldata responseData
    ) external {
        if (query.status != IQueryConsumer.QueryStatus.Pending && query.status != IQueryConsumer.QueryStatus.InProgress)
        {
            revert IQueryConsumer.QueryNotPending(queryId);
        }
        if (block.timestamp > query.deadline) revert IQueryConsumer.QueryExpired(queryId);
        if (!isAssigned[agentId]) revert IQueryConsumer.NotAssignedAgent(queryId, agentId);
        if (hasResponded[agentId]) revert IQueryConsumer.AlreadyResponded(queryId, agentId);
        if (responseData.length > MAX_RESPONSE_DATA_LENGTH) revert IQueryConsumer.PayloadTooLarge();

        if (query.status == IQueryConsumer.QueryStatus.Pending) query.status = IQueryConsumer.QueryStatus.InProgress;

        responses.push(
            IQueryConsumer.ResponseInfo({
                agentId: agentId,
                responseData: responseData,
                submittedAt: block.timestamp,
                validated: false
            })
        );
        hasResponded[agentId] = true;

        emit IQueryConsumer.ResponseSubmitted(queryId, agentId, block.timestamp);
    }

    /**
     * @notice Returns the owner of an agent; reverts for unknown agents
     * @param agentRegistry The agent registry
     * @param agentId The agent
     * @return owner The agent owner
     */
    function agentOwner(IAgentRegistry agentRegistry, bytes32 agentId) external view returns (address owner) {
        return agentRegistry.getAgent(agentId).owner;
    }

    /**
     * @notice Reverts unless `signature` is a valid ECDSA or ERC-1271 signature of the agent owner
     * @param agentRegistry The agent registry
     * @param agentId The agent whose owner must have signed
     * @param digest The EIP-712 response digest
     * @param signature The signature
     */
    function verifyAgentSignature(
        IAgentRegistry agentRegistry,
        bytes32 agentId,
        bytes32 digest,
        bytes calldata signature
    ) external view {
        address owner = agentRegistry.getAgent(agentId).owner;
        if (!SignatureChecker.isValidSignatureNow(owner, digest, signature)) revert IQueryConsumer.InvalidSignature();
    }
}
