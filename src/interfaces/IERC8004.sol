// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IERC8004
 * @author Berke (pzzaworks)
 * @notice ERC8004 Agent Identity Standard Interface
 * @dev Defines the standard interface for agent identity management on-chain.
 *      Agents are autonomous entities with verifiable identities, capabilities,
 *      and TEE (Trusted Execution Environment) attestations.
 */
interface IERC8004 {
    /// @notice Agent identity structure
    struct AgentInfo {
        bytes32 agentId;
        address owner;
        string endpoint;
        string[] capabilities;
        bytes attestation;
        uint256 registeredAt;
        string metadataURI;
    }

    /// @notice Emitted when a new agent is registered
    /// @param agentId The unique identifier of the agent
    /// @param owner The owner address of the agent
    /// @param endpoint The agent's service endpoint
    event AgentRegistered(bytes32 indexed agentId, address indexed owner, string endpoint);

    /// @notice Emitted when an agent's information is updated
    /// @param agentId The unique identifier of the agent
    /// @param endpoint The updated endpoint
    event AgentUpdated(bytes32 indexed agentId, string endpoint);

    /// @notice Emitted when an agent is suspended
    /// @param agentId The unique identifier of the agent
    /// @param reason The reason for suspension
    event AgentSuspended(bytes32 indexed agentId, string reason);

    /**
     * @notice Registers a new agent with the given parameters
     * @param endpoint The agent's service endpoint URL
     * @param capabilities Array of capability strings the agent supports
     * @param attestation TEE attestation bytes proving secure execution
     * @return agentId The unique identifier assigned to the agent
     */
    function registerAgent(
        string calldata endpoint,
        string[] calldata capabilities,
        bytes calldata attestation,
        string calldata metadataURI
    ) external returns (bytes32 agentId);

    /**
     * @notice Updates an existing agent's information
     * @param agentId The unique identifier of the agent
     * @param endpoint The new endpoint URL
     * @param capabilities The updated capabilities array
     * @param attestation The updated TEE attestation
     */
    function updateAgent(
        bytes32 agentId,
        string calldata endpoint,
        string[] calldata capabilities,
        bytes calldata attestation
    ) external;

    /**
     * @notice Suspends an agent
     * @param agentId The unique identifier of the agent
     * @param reason The reason for suspension
     */
    function suspendAgent(bytes32 agentId, string calldata reason) external;

    /**
     * @notice Retrieves agent information
     * @param agentId The unique identifier of the agent
     * @return info The agent's full information struct
     */
    function getAgent(bytes32 agentId) external view returns (AgentInfo memory info);

    /**
     * @notice Checks if an agent is currently active
     * @param agentId The unique identifier of the agent
     * @return active True if the agent is active, false otherwise
     */
    function isActiveAgent(bytes32 agentId) external view returns (bool active);

    /**
     * @notice Updates an agent's metadata URI
     * @param agentId The unique identifier of the agent
     * @param metadataURI The new metadata URI
     */
    function updateMetadataURI(bytes32 agentId, string calldata metadataURI) external;
}
