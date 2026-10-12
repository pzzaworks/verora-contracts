// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ReputationManager
 * @author Berke (pzzaworks)
 * @notice Track agent reputation from settled query outcomes
 * @dev Implements success-rate scoring with inactivity decay, recorded only by authorized contracts
 */
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IReputationManager} from "./interfaces/IReputationManager.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";

contract ReputationManager is IReputationManager, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum reputation score (100% in basis points)
    uint256 public constant MAX_REPUTATION = 10_000;

    /// @notice Initial reputation for new agents
    uint256 public constant INITIAL_REPUTATION = 5000;

    /// @notice Decay period (30 days in seconds)
    uint256 public constant DECAY_PERIOD = 30 days;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Reference to the AgentRegistry contract
    IAgentRegistry public immutable agentRegistry;

    /// @notice Mapping from agent ID to query statistics
    mapping(bytes32 => QueryStats) private _queryStats;

    /// @notice Mapping to track processed query IDs per agent (agentId => queryId => processed)
    mapping(bytes32 => mapping(bytes32 => bool)) private _processedQueries;

    /// @notice Decay factor in basis points (default 500 = 5% decay per period)
    uint256 private _decayFactor;

    /// @notice Authorized recorders (QueryConsumer, etc.)
    mapping(address => bool) public authorizedRecorders;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AgentNotFound(bytes32 agentId);
    error QueryAlreadyRecorded(bytes32 queryId);
    error NotAuthorizedRecorder(address caller);
    error InvalidDecayFactor(uint256 factor);
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RecorderAuthorized(address indexed recorder, bool authorized);
    event DecayFactorUpdated(uint256 oldFactor, uint256 newFactor);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the ReputationManager contract
     * @param initialOwner The initial owner of the contract
     * @param agentRegistry_ The AgentRegistry contract address
     */
    constructor(address initialOwner, address agentRegistry_) Ownable(initialOwner) {
        if (agentRegistry_ == address(0)) revert ZeroAddress();
        agentRegistry = IAgentRegistry(agentRegistry_);
        _decayFactor = 500; // 5% default decay
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAuthorizedRecorder() {
        if (!authorizedRecorders[msg.sender] && msg.sender != owner()) revert NotAuthorizedRecorder(msg.sender);
        _;
    }

    /// @dev Only requires existence: outcomes must be recordable for suspended or slashed agents too,
    ///      otherwise an agent changing status could block query settlement.
    modifier validAgent(bytes32 agentId) {
        if (!agentRegistry.agentExists(agentId)) revert AgentNotFound(agentId);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IReputationManager
     */
    function recordSuccess(bytes32 agentId, bytes32 queryId)
        external
        override
        onlyAuthorizedRecorder
        validAgent(agentId)
    {
        if (_processedQueries[agentId][queryId]) revert QueryAlreadyRecorded(queryId);

        _processedQueries[agentId][queryId] = true;

        QueryStats storage stats = _queryStats[agentId];
        stats.totalQueries++;
        stats.successfulQueries++;
        stats.lastQueryTimestamp = block.timestamp;

        _updateReputation(agentId);

        emit QueryRecorded(agentId, queryId, true);
    }

    /**
     * @inheritdoc IReputationManager
     */
    function recordFailure(bytes32 agentId, bytes32 queryId)
        external
        override
        onlyAuthorizedRecorder
        validAgent(agentId)
    {
        if (_processedQueries[agentId][queryId]) revert QueryAlreadyRecorded(queryId);

        _processedQueries[agentId][queryId] = true;

        QueryStats storage stats = _queryStats[agentId];
        stats.totalQueries++;
        stats.failedQueries++;
        stats.lastQueryTimestamp = block.timestamp;

        _updateReputation(agentId);

        emit QueryRecorded(agentId, queryId, false);
    }

    /**
     * @inheritdoc IReputationManager
     */
    function getReputation(bytes32 agentId) external view override returns (uint256 reputation) {
        return _calculateReputation(agentId);
    }

    /**
     * @inheritdoc IReputationManager
     */
    function getQueryStats(bytes32 agentId) external view override returns (QueryStats memory stats) {
        return _queryStats[agentId];
    }

    /**
     * @inheritdoc IReputationManager
     */
    function getDecayFactor() external view override returns (uint256 factor) {
        return _decayFactor;
    }

    /**
     * @inheritdoc IReputationManager
     */
    function setDecayFactor(uint256 factor) external override onlyOwner {
        if (factor > MAX_REPUTATION) revert InvalidDecayFactor(factor);

        uint256 oldFactor = _decayFactor;
        _decayFactor = factor;

        emit DecayFactorUpdated(oldFactor, factor);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes or deauthorizes an address to record queries
     * @param recorder The address to authorize/deauthorize
     * @param authorized Whether to authorize or deauthorize
     */
    function setAuthorizedRecorder(address recorder, bool authorized) external onlyOwner {
        if (recorder == address(0)) revert ZeroAddress();
        authorizedRecorders[recorder] = authorized;
        emit RecorderAuthorized(recorder, authorized);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emits the recalculated reputation for an agent
     * @param agentId The agent to update
     */
    function _updateReputation(bytes32 agentId) internal {
        emit ReputationUpdated(agentId, _calculateReputation(agentId), _queryStats[agentId].totalQueries);
    }

    /**
     * @notice Calculates the current reputation for an agent
     * @param agentId The agent to calculate for
     * @return reputation The calculated reputation score
     */
    function _calculateReputation(bytes32 agentId) internal view returns (uint256 reputation) {
        QueryStats storage stats = _queryStats[agentId];

        // Return initial reputation if no queries
        if (stats.totalQueries == 0) return INITIAL_REPUTATION;

        // Calculate base reputation from success rate
        uint256 baseReputation = (stats.successfulQueries * MAX_REPUTATION) / stats.totalQueries;

        // Apply time-based decay if there's been inactivity
        if (stats.lastQueryTimestamp > 0) {
            uint256 timeSinceLastQuery = block.timestamp - stats.lastQueryTimestamp;

            if (timeSinceLastQuery > DECAY_PERIOD) {
                // Calculate decay periods elapsed
                uint256 decayPeriods = timeSinceLastQuery / DECAY_PERIOD;

                // Apply decay for each period (compound decay)
                for (uint256 i = 0; i < decayPeriods && i < 10; i++) {
                    // Cap at 10 periods
                    uint256 decayAmount = (baseReputation * _decayFactor) / MAX_REPUTATION;
                    if (decayAmount >= baseReputation) {
                        baseReputation = 0;
                        break;
                    }
                    baseReputation -= decayAmount;
                }
            }
        }

        return baseReputation;
    }
}
