// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAgentRegistry
 * @author Berke (pzzaworks)
 * @notice Interface for the Verora agent registry
 * @dev Extends ERC8004 identities with status, enumeration, and slashing hooks
 */
import {IERC8004} from "./IERC8004.sol";

interface IAgentRegistry is IERC8004 {
    /// @notice Agent status enumeration
    enum AgentStatus {
        Inactive,
        Active,
        Suspended,
        Slashed
    }

    /**
     * @notice Gets the current status of an agent
     * @param agentId The unique identifier of the agent
     * @return status The agent's current status
     */
    function getAgentStatus(bytes32 agentId) external view returns (AgentStatus status);

    /**
     * @notice Gets all agents owned by an address
     * @param owner The owner address to query
     * @return agentIds Array of agent IDs owned by the address
     */
    function getAgentsByOwner(address owner) external view returns (bytes32[] memory agentIds);

    /**
     * @notice Gets the total number of registered agents
     * @return count The total agent count
     */
    function getAgentCount() external view returns (uint256 count);

    /**
     * @notice Slashes an agent (called by authorized contracts)
     * @param agentId The unique identifier of the agent
     */
    function slashAgent(bytes32 agentId) external;

    /**
     * @notice Reactivates a suspended agent
     * @param agentId The unique identifier of the agent
     */
    function reactivateAgent(bytes32 agentId) external;

    /**
     * @notice Gets all registered agent IDs
     * @return Array of all agent IDs
     */
    function getAllAgentIds() external view returns (bytes32[] memory);

    /**
     * @notice Gets the agent ID at a specific index
     * @param index The index in the agent IDs array
     * @return The agent ID at the given index
     */
    function getAgentAtIndex(uint256 index) external view returns (bytes32);

    /**
     * @notice Returns a page of agent IDs in registration order
     * @param offset Index of the first agent ID to return
     * @param limit Maximum number of agent IDs to return
     */
    function getAgentIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory agentIds);

    /**
     * @notice Whether an agent exists (in any status)
     */
    function agentExists(bytes32 agentId) external view returns (bool exists);

    /**
     * @notice Updates an agent's metadata URI
     * @param agentId The unique identifier of the agent
     * @param metadataURI The new metadata URI
     */
    function updateMetadataURI(bytes32 agentId, string calldata metadataURI) external;

    /// @notice Emitted when an agent's metadata URI is updated
    /// @param agentId The unique identifier of the agent
    /// @param metadataURI The new metadata URI
    event MetadataURIUpdated(bytes32 indexed agentId, string metadataURI);
}
