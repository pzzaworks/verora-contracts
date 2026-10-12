// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title AgentRegistry
 * @author Berke (pzzaworks)
 * @notice Register and manage AI agent identities on the Verora network
 * @dev Implements ERC8004 agent identities with owner, admin, and slashing status controls
 */
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {IERC8004} from "./interfaces/IERC8004.sol";

contract AgentRegistry is IAgentRegistry, Ownable2Step, Pausable {
    /// @notice Input bounds for registration data
    uint256 public constant MAX_ENDPOINT_LENGTH = 512;
    uint256 public constant MAX_METADATA_URI_LENGTH = 512;
    uint256 public constant MAX_CAPABILITIES = 32;
    uint256 public constant MAX_CAPABILITY_LENGTH = 64;
    uint256 public constant MAX_ATTESTATION_LENGTH = 4096;

    /// @notice Agents suspended by the owner; only the owner can lift this
    mapping(bytes32 => bool) public adminSuspended;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping from agent ID to agent information
    mapping(bytes32 => AgentInfo) private _agents;

    /// @notice Mapping from agent ID to agent status
    mapping(bytes32 => AgentStatus) private _agentStatus;

    /// @notice Mapping from owner address to their agent IDs
    mapping(address => bytes32[]) private _ownerAgents;

    /// @notice Mapping to track agent ID existence
    mapping(bytes32 => bool) private _agentExists;

    /// @notice Array of all registered agent IDs
    bytes32[] private _allAgentIds;

    /// @notice Nonce for generating unique agent IDs
    uint256 private _nonce;

    /// @notice Authorized contracts that can slash agents
    mapping(address => bool) public authorizedSlashers;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AgentNotFound(bytes32 agentId);
    error AgentAlreadyExists(bytes32 agentId);
    error NotAgentOwner(bytes32 agentId, address caller);
    error AgentNotActive(bytes32 agentId);
    error AgentAlreadyActive(bytes32 agentId);
    error InvalidEndpoint();
    error NotAuthorizedSlasher(address caller);
    error AgentIsSlashed(bytes32 agentId);
    error AgentIsAdminSuspended(bytes32 agentId);
    error InvalidCapabilities();
    error InvalidMetadataURI();
    error InvalidAttestation();
    error IndexOutOfBounds(uint256 index, uint256 length);
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SlasherAuthorized(address indexed slasher, bool authorized);
    event AgentSlashed(bytes32 indexed agentId);
    event AgentReactivated(bytes32 indexed agentId);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the AgentRegistry contract
     * @param initialOwner The initial owner of the contract
     */
    constructor(address initialOwner) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAgentOwner(bytes32 agentId) {
        if (!_agentExists[agentId]) revert AgentNotFound(agentId);
        if (_agents[agentId].owner != msg.sender) revert NotAgentOwner(agentId, msg.sender);
        _;
    }

    modifier onlyActiveAgent(bytes32 agentId) {
        if (!_agentExists[agentId]) revert AgentNotFound(agentId);
        if (_agentStatus[agentId] != AgentStatus.Active) revert AgentNotActive(agentId);
        _;
    }

    modifier onlyAuthorizedSlasher() {
        if (!authorizedSlashers[msg.sender] && msg.sender != owner()) revert NotAuthorizedSlasher(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IERC8004
     */
    function registerAgent(
        string calldata endpoint,
        string[] calldata capabilities,
        bytes calldata attestation,
        string calldata metadataURI
    ) external override whenNotPaused returns (bytes32 agentId) {
        _validateAgentData(endpoint, capabilities, attestation);
        if (bytes(metadataURI).length > MAX_METADATA_URI_LENGTH) revert InvalidMetadataURI();

        // Generate unique agent ID
        agentId = keccak256(abi.encodePacked(msg.sender, block.timestamp, _nonce++));

        // Ensure uniqueness (extremely unlikely to collide, but safety first)
        if (_agentExists[agentId]) revert AgentAlreadyExists(agentId);

        // Create agent info
        AgentInfo storage agent = _agents[agentId];
        agent.agentId = agentId;
        agent.owner = msg.sender;
        agent.endpoint = endpoint;
        agent.capabilities = capabilities;
        agent.attestation = attestation;
        agent.registeredAt = block.timestamp;
        agent.metadataURI = metadataURI;

        // Set status and tracking
        _agentStatus[agentId] = AgentStatus.Active;
        _agentExists[agentId] = true;
        _ownerAgents[msg.sender].push(agentId);
        _allAgentIds.push(agentId);

        emit AgentRegistered(agentId, msg.sender, endpoint);
    }

    /**
     * @inheritdoc IERC8004
     */
    function updateAgent(
        bytes32 agentId,
        string calldata endpoint,
        string[] calldata capabilities,
        bytes calldata attestation
    ) external override onlyAgentOwner(agentId) onlyActiveAgent(agentId) {
        _validateAgentData(endpoint, capabilities, attestation);

        AgentInfo storage agent = _agents[agentId];
        agent.endpoint = endpoint;
        agent.capabilities = capabilities;
        agent.attestation = attestation;

        emit AgentUpdated(agentId, endpoint);
    }

    /**
     * @inheritdoc IERC8004
     */
    function suspendAgent(bytes32 agentId, string calldata reason)
        external
        override
        onlyAgentOwner(agentId)
        onlyActiveAgent(agentId)
    {
        _agentStatus[agentId] = AgentStatus.Suspended;
        emit AgentSuspended(agentId, reason);
    }

    /**
     * @inheritdoc IERC8004
     */
    function getAgent(bytes32 agentId) external view override returns (AgentInfo memory info) {
        if (!_agentExists[agentId]) revert AgentNotFound(agentId);
        return _agents[agentId];
    }

    /**
     * @inheritdoc IERC8004
     */
    function isActiveAgent(bytes32 agentId) external view override returns (bool active) {
        if (!_agentExists[agentId]) return false;
        return _agentStatus[agentId] == AgentStatus.Active;
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function getAgentStatus(bytes32 agentId) external view override returns (AgentStatus status) {
        if (!_agentExists[agentId]) revert AgentNotFound(agentId);
        return _agentStatus[agentId];
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function getAgentsByOwner(address owner_) external view override returns (bytes32[] memory agentIds) {
        return _ownerAgents[owner_];
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function getAgentCount() external view override returns (uint256 count) {
        return _allAgentIds.length;
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function slashAgent(bytes32 agentId) external override onlyAuthorizedSlasher {
        if (!_agentExists[agentId]) revert AgentNotFound(agentId);
        // Idempotent so repeated stake slashes for the same agent keep working
        if (_agentStatus[agentId] == AgentStatus.Slashed) return;

        _agentStatus[agentId] = AgentStatus.Slashed;
        emit AgentSlashed(agentId);
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function reactivateAgent(bytes32 agentId) external override onlyAgentOwner(agentId) {
        if (_agentStatus[agentId] == AgentStatus.Slashed) revert AgentIsSlashed(agentId);
        if (adminSuspended[agentId]) revert AgentIsAdminSuspended(agentId);
        if (_agentStatus[agentId] == AgentStatus.Active) revert AgentAlreadyActive(agentId);

        _agentStatus[agentId] = AgentStatus.Active;
        emit AgentReactivated(agentId);
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function getAllAgentIds() external view override returns (bytes32[] memory) {
        return _allAgentIds;
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function getAgentAtIndex(uint256 index) external view override returns (bytes32) {
        if (index >= _allAgentIds.length) revert IndexOutOfBounds(index, _allAgentIds.length);
        return _allAgentIds[index];
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function getAgentIds(uint256 offset, uint256 limit) external view override returns (bytes32[] memory agentIds) {
        uint256 total = _allAgentIds.length;
        if (offset >= total) return new bytes32[](0);

        uint256 end = limit > total - offset ? total : offset + limit;
        agentIds = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            agentIds[i - offset] = _allAgentIds[i];
        }
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function agentExists(bytes32 agentId) external view override returns (bool exists) {
        return _agentExists[agentId];
    }

    /**
     * @inheritdoc IAgentRegistry
     */
    function updateMetadataURI(bytes32 agentId, string calldata metadataURI)
        external
        override
        onlyAgentOwner(agentId)
    {
        if (bytes(metadataURI).length > MAX_METADATA_URI_LENGTH) revert InvalidMetadataURI();
        _agents[agentId].metadataURI = metadataURI;
        emit MetadataURIUpdated(agentId, metadataURI);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes or deauthorizes an address to slash agents
     * @param slasher The address to authorize/deauthorize
     * @param authorized Whether to authorize or deauthorize
     */
    function setAuthorizedSlasher(address slasher, bool authorized) external onlyOwner {
        if (slasher == address(0)) revert ZeroAddress();
        authorizedSlashers[slasher] = authorized;
        emit SlasherAuthorized(slasher, authorized);
    }

    /**
     * @notice Admin function to suspend an agent. The owner of the agent can't lift this.
     * @param agentId The agent to suspend
     * @param reason The reason for suspension
     */
    function adminSuspendAgent(bytes32 agentId, string calldata reason) external onlyOwner {
        if (!_agentExists[agentId]) revert AgentNotFound(agentId);
        adminSuspended[agentId] = true;
        _agentStatus[agentId] = AgentStatus.Suspended;
        emit AgentSuspended(agentId, reason);
    }

    /**
     * @notice Admin function to reactivate a suspended or slashed agent
     * @param agentId The agent to reactivate
     */
    function adminReactivateAgent(bytes32 agentId) external onlyOwner {
        if (!_agentExists[agentId]) revert AgentNotFound(agentId);
        adminSuspended[agentId] = false;
        _agentStatus[agentId] = AgentStatus.Active;
        emit AgentReactivated(agentId);
    }

    /// @notice Pauses new agent registrations
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes agent registrations
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _validateAgentData(string calldata endpoint, string[] calldata capabilities, bytes calldata attestation)
        internal
        pure
    {
        uint256 endpointLength = bytes(endpoint).length;
        if (endpointLength == 0 || endpointLength > MAX_ENDPOINT_LENGTH) revert InvalidEndpoint();
        if (capabilities.length > MAX_CAPABILITIES) revert InvalidCapabilities();
        for (uint256 i = 0; i < capabilities.length; i++) {
            uint256 length = bytes(capabilities[i]).length;
            if (length == 0 || length > MAX_CAPABILITY_LENGTH) revert InvalidCapabilities();
        }
        if (attestation.length > MAX_ATTESTATION_LENGTH) revert InvalidAttestation();
    }
}
