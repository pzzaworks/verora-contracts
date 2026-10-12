// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IReputationManager
 * @author Berke (pzzaworks)
 * @notice Interface for the Reputation Manager contract
 * @dev Manages agent reputation scores based on query success/failure rates
 */
interface IReputationManager {
    /// @notice Query statistics structure
    struct QueryStats {
        uint256 totalQueries;
        uint256 successfulQueries;
        uint256 failedQueries;
        uint256 lastQueryTimestamp;
    }

    /// @notice Emitted when reputation is updated
    /// @param agentId The agent whose reputation was updated
    /// @param newReputation The new reputation score (0-10000 basis points)
    /// @param totalQueries Total queries processed by the agent
    event ReputationUpdated(bytes32 indexed agentId, uint256 newReputation, uint256 totalQueries);

    /// @notice Emitted when a query is recorded
    /// @param agentId The agent that processed the query
    /// @param queryId The unique query identifier
    /// @param success Whether the query was successful
    event QueryRecorded(bytes32 indexed agentId, bytes32 indexed queryId, bool success);

    /**
     * @notice Records a successful query for an agent
     * @param agentId The agent that processed the query
     * @param queryId The unique query identifier
     */
    function recordSuccess(bytes32 agentId, bytes32 queryId) external;

    /**
     * @notice Records a failed query for an agent
     * @param agentId The agent that processed the query
     * @param queryId The unique query identifier
     */
    function recordFailure(bytes32 agentId, bytes32 queryId) external;

    /**
     * @notice Gets the current reputation score of an agent
     * @param agentId The agent to query
     * @return reputation The reputation score (0-10000 basis points)
     */
    function getReputation(bytes32 agentId) external view returns (uint256 reputation);

    /**
     * @notice Gets the query statistics for an agent
     * @param agentId The agent to query
     * @return stats The query statistics struct
     */
    function getQueryStats(bytes32 agentId) external view returns (QueryStats memory stats);

    /**
     * @notice Gets the decay factor for reputation calculation
     * @return factor The decay factor in basis points
     */
    function getDecayFactor() external view returns (uint256 factor);

    /**
     * @notice Sets the decay factor for reputation calculation
     * @param factor The new decay factor in basis points
     */
    function setDecayFactor(uint256 factor) external;
}
