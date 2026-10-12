// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IStakingPool
 * @author Berke (pzzaworks)
 * @notice Interface for the Staking Pool contract
 * @dev Share-based staking per agent: slashing is pro-rata in O(1) and also hits unbonding stake
 */
interface IStakingPool {
    /// @notice Computed view of a staker's position on an agent
    struct StakeInfo {
        uint256 amount; // Current ETH value of active (non-unbonding) shares
        uint256 shares; // Active shares
        uint256 stakedAt; // First stake timestamp of the current position
        uint256 pendingRewards; // Claimable rewards, including accrued ones
        uint256 unbondingAmount; // Current ETH value of all unbonding shares
        uint256 withdrawableAmount; // Current ETH value of unbonding shares that are already unlocked
        uint256 nextUnlockTime; // Earliest unlock time among still-locked requests (0 if none)
    }

    event Staked(bytes32 indexed agentId, address indexed staker, uint256 amount, uint256 shares);
    event Unstaked(bytes32 indexed agentId, address indexed staker, uint256 amount, uint256 shares, uint256 unlockTime);
    event Withdrawn(bytes32 indexed agentId, address indexed staker, uint256 amount);
    event Slashed(bytes32 indexed agentId, uint256 amount, string reason);
    event RewardsDistributed(bytes32 indexed agentId, uint256 amount);
    event RewardsClaimed(bytes32 indexed agentId, address indexed staker, uint256 amount);

    function stake(bytes32 agentId) external payable;

    /**
     * @notice Starts unbonding `amount` of ETH-denominated stake (type(uint256).max = everything)
     */
    function unstake(bytes32 agentId, uint256 amount) external;

    /**
     * @notice Withdraws all unlocked unbonding requests for an agent
     */
    function withdraw(bytes32 agentId) external;

    function slash(bytes32 agentId, uint256 percentage, string calldata reason) external;

    function claimRewards(bytes32 agentId) external;

    function distributeRewards(bytes32 agentId) external payable;

    function getStake(bytes32 agentId, address staker) external view returns (StakeInfo memory info);

    function getTotalStake(bytes32 agentId) external view returns (uint256 total);

    function getStakerCount(bytes32 agentId) external view returns (uint256 count);

    function getMinimumStake() external view returns (uint256 minimum);

    function setMinimumStake(uint256 minimum) external;

    function getUnstakingPeriod() external view returns (uint256 period);

    function setUnstakingPeriod(uint256 period) external;
}
