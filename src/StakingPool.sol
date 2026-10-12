// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title StakingPool
 * @author Berke (pzzaworks)
 * @notice Stake ETH behind Verora agents and earn a share of their query fees
 * @dev Implements share-based staking with unbonding, pro-rata slashing, and O(1) reward distribution.
 *      `pooled` ETH backs active and unbonding shares, so unbonding stake can't escape a slash; rewards use an
 *      accumulator over active shares only.
 */
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";

contract StakingPool is IStakingPool, Ownable2Step, Pausable, ReentrancyGuard {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_SLASH_BPS = 5000;
    uint256 public constant MAX_UNSTAKING_PERIOD = 30 days;
    uint256 public constant MAX_UNBONDING_REQUESTS = 20;
    uint256 private constant ACC_PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct Pool {
        uint256 totalShares; // Active + unbonding shares
        uint256 activeShares; // Shares earning rewards
        uint256 pooled; // ETH backing totalShares
        uint256 accRewardPerShare; // Scaled by ACC_PRECISION
        uint256 stakerCount; // Stakers with active shares
    }

    struct Position {
        uint256 shares;
        uint256 stakedAt;
        uint256 rewardDebt;
        uint256 pendingRewards;
    }

    struct UnbondingRequest {
        uint256 shares;
        uint256 unlockTime;
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    IAgentRegistry public immutable agentRegistry;
    address public treasury;

    uint256 private _minimumStake;
    uint256 private _unstakingPeriod;

    mapping(bytes32 => Pool) private _pools;
    mapping(bytes32 => mapping(address => Position)) private _positions;
    mapping(bytes32 => mapping(address => UnbondingRequest[])) private _unbonding;

    mapping(address => bool) public authorizedSlashers;

    /// @dev Reward remainder per agent, scaled by ACC_PRECISION, carried into the next distribution
    mapping(bytes32 => uint256) private _rewardDust;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AgentNotActive(bytes32 agentId);
    error InsufficientStake(uint256 required, uint256 provided);
    error InsufficientBalance(uint256 requested, uint256 available);
    error UnstakingPeriodNotElapsed(uint256 unlockTime);
    error NoPendingUnstake();
    error TooManyUnbondingRequests();
    error PoolInsolvent(bytes32 agentId);
    error InvalidSlashPercentage(uint256 percentage);
    error InvalidUnstakingPeriod(uint256 period);
    error NotAuthorizedSlasher(address caller);
    error ZeroAddress();
    error TransferFailed();
    error NothingToClaim();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event MinimumStakeUpdated(uint256 oldMinimum, uint256 newMinimum);
    event UnstakingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event SlasherAuthorized(address indexed slasher, bool authorized);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the StakingPool contract
     * @param initialOwner The initial owner of the contract
     * @param agentRegistry_ The AgentRegistry contract address
     * @param treasury_ The treasury that receives slashed stake
     * @param minimumStake_ Minimum stake per deposit, in wei
     * @param unstakingPeriod_ Unbonding delay in seconds
     */
    constructor(
        address initialOwner,
        address agentRegistry_,
        address treasury_,
        uint256 minimumStake_,
        uint256 unstakingPeriod_
    ) Ownable(initialOwner) {
        if (agentRegistry_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (unstakingPeriod_ > MAX_UNSTAKING_PERIOD) revert InvalidUnstakingPeriod(unstakingPeriod_);

        agentRegistry = IAgentRegistry(agentRegistry_);
        treasury = treasury_;
        _minimumStake = minimumStake_;
        _unstakingPeriod = unstakingPeriod_;
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAuthorizedSlasher() {
        if (!authorizedSlashers[msg.sender] && msg.sender != owner()) revert NotAuthorizedSlasher(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingPool
    function stake(bytes32 agentId) external payable override nonReentrant whenNotPaused {
        if (!agentRegistry.isActiveAgent(agentId)) revert AgentNotActive(agentId);
        if (msg.value == 0 || msg.value < _minimumStake) revert InsufficientStake(_minimumStake, msg.value);

        Pool storage pool = _pools[agentId];
        Position storage position = _positions[agentId][msg.sender];

        if (pool.totalShares > 0 && pool.pooled == 0) revert PoolInsolvent(agentId);

        uint256 shares = pool.totalShares == 0 ? msg.value : msg.value.mulDiv(pool.totalShares, pool.pooled);
        if (shares == 0) revert InsufficientStake(_minimumStake, msg.value);

        _harvest(pool, position);

        if (position.shares == 0) {
            position.stakedAt = block.timestamp;
            pool.stakerCount++;
        }

        position.shares += shares;
        pool.activeShares += shares;
        pool.totalShares += shares;
        pool.pooled += msg.value;
        position.rewardDebt = _accrued(pool, position.shares);

        emit Staked(agentId, msg.sender, msg.value, shares);
    }

    /// @inheritdoc IStakingPool
    function unstake(bytes32 agentId, uint256 amount) external override nonReentrant {
        Pool storage pool = _pools[agentId];
        Position storage position = _positions[agentId][msg.sender];

        uint256 shares;
        if (amount == type(uint256).max) {
            shares = position.shares;
        } else if (pool.pooled > 0) {
            // Round up so a staker can never unbond more value than their shares are worth
            shares = amount.mulDiv(pool.totalShares, pool.pooled, Math.Rounding.Ceil);
        }
        if (shares == 0 || shares > position.shares) {
            revert InsufficientBalance(amount, _sharesToAmount(pool, position.shares));
        }

        UnbondingRequest[] storage requests = _unbonding[agentId][msg.sender];
        if (requests.length >= MAX_UNBONDING_REQUESTS) revert TooManyUnbondingRequests();

        _harvest(pool, position);

        position.shares -= shares;
        pool.activeShares -= shares;
        position.rewardDebt = _accrued(pool, position.shares);

        if (position.shares == 0) {
            position.stakedAt = 0;
            pool.stakerCount--;
        }

        uint256 unlockTime = block.timestamp + _unstakingPeriod;
        requests.push(UnbondingRequest({shares: shares, unlockTime: unlockTime}));

        emit Unstaked(agentId, msg.sender, _sharesToAmount(pool, shares), shares, unlockTime);
    }

    /// @inheritdoc IStakingPool
    function withdraw(bytes32 agentId) external override nonReentrant {
        UnbondingRequest[] storage requests = _unbonding[agentId][msg.sender];
        if (requests.length == 0) revert NoPendingUnstake();

        uint256 shares;
        uint256 earliestLocked = type(uint256).max;
        uint256 i = 0;
        while (i < requests.length) {
            if (requests[i].unlockTime <= block.timestamp) {
                shares += requests[i].shares;
                requests[i] = requests[requests.length - 1];
                requests.pop();
            } else {
                if (requests[i].unlockTime < earliestLocked) earliestLocked = requests[i].unlockTime;
                i++;
            }
        }
        if (shares == 0) revert UnstakingPeriodNotElapsed(earliestLocked);

        Pool storage pool = _pools[agentId];
        uint256 amount = _sharesToAmount(pool, shares);
        pool.totalShares -= shares;
        pool.pooled -= amount;

        if (amount > 0) {
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert TransferFailed();
        }

        emit Withdrawn(agentId, msg.sender, amount);
    }

    /// @inheritdoc IStakingPool
    function slash(bytes32 agentId, uint256 percentage, string calldata reason)
        external
        override
        nonReentrant
        onlyAuthorizedSlasher
    {
        if (percentage == 0 || percentage > MAX_SLASH_BPS) revert InvalidSlashPercentage(percentage);

        Pool storage pool = _pools[agentId];
        uint256 slashAmount = (pool.pooled * percentage) / MAX_BPS;
        pool.pooled -= slashAmount;

        agentRegistry.slashAgent(agentId);

        if (slashAmount > 0) {
            (bool success,) = treasury.call{value: slashAmount}("");
            if (!success) revert TransferFailed();
        }

        emit Slashed(agentId, slashAmount, reason);
    }

    /// @inheritdoc IStakingPool
    function claimRewards(bytes32 agentId) external override nonReentrant {
        Pool storage pool = _pools[agentId];
        Position storage position = _positions[agentId][msg.sender];

        _harvest(pool, position);

        uint256 rewards = position.pendingRewards;
        if (rewards == 0) revert NothingToClaim();
        position.pendingRewards = 0;

        (bool success,) = msg.sender.call{value: rewards}("");
        if (!success) revert TransferFailed();

        emit RewardsClaimed(agentId, msg.sender, rewards);
    }

    /// @inheritdoc IStakingPool
    function distributeRewards(bytes32 agentId) external payable override nonReentrant {
        if (msg.value == 0) return;

        Pool storage pool = _pools[agentId];
        if (pool.activeShares == 0) {
            (bool success,) = treasury.call{value: msg.value}("");
            if (!success) revert TransferFailed();
            return;
        }

        // Carry the division remainder forward so small rewards are never silently lost
        uint256 scaled = msg.value * ACC_PRECISION + _rewardDust[agentId];
        uint256 increment = scaled / pool.activeShares;
        pool.accRewardPerShare += increment;
        _rewardDust[agentId] = scaled - increment * pool.activeShares;

        emit RewardsDistributed(agentId, msg.value);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingPool
    function getStake(bytes32 agentId, address staker) external view override returns (StakeInfo memory info) {
        Pool storage pool = _pools[agentId];
        Position storage position = _positions[agentId][staker];
        UnbondingRequest[] storage requests = _unbonding[agentId][staker];

        uint256 unbondingShares;
        uint256 unlockedShares;
        uint256 nextUnlock;
        for (uint256 i = 0; i < requests.length; i++) {
            unbondingShares += requests[i].shares;
            if (requests[i].unlockTime <= block.timestamp) unlockedShares += requests[i].shares;
            else if (nextUnlock == 0 || requests[i].unlockTime < nextUnlock) nextUnlock = requests[i].unlockTime;
        }

        info = StakeInfo({
            amount: _sharesToAmount(pool, position.shares),
            shares: position.shares,
            stakedAt: position.stakedAt,
            pendingRewards: position.pendingRewards + _accrued(pool, position.shares) - position.rewardDebt,
            unbondingAmount: _sharesToAmount(pool, unbondingShares),
            withdrawableAmount: _sharesToAmount(pool, unlockedShares),
            nextUnlockTime: nextUnlock
        });
    }

    /// @inheritdoc IStakingPool
    function getTotalStake(bytes32 agentId) external view override returns (uint256 total) {
        Pool storage pool = _pools[agentId];
        return _sharesToAmount(pool, pool.activeShares);
    }

    /// @inheritdoc IStakingPool
    function getStakerCount(bytes32 agentId) external view override returns (uint256 count) {
        return _pools[agentId].stakerCount;
    }

    /// @inheritdoc IStakingPool
    function getMinimumStake() external view override returns (uint256 minimum) {
        return _minimumStake;
    }

    /// @inheritdoc IStakingPool
    function getUnstakingPeriod() external view override returns (uint256 period) {
        return _unstakingPeriod;
    }

    /// @notice Raw pool accounting for an agent
    function getPool(bytes32 agentId) external view returns (Pool memory pool) {
        return _pools[agentId];
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingPool
    function setMinimumStake(uint256 minimum) external override onlyOwner {
        uint256 oldMinimum = _minimumStake;
        _minimumStake = minimum;
        emit MinimumStakeUpdated(oldMinimum, minimum);
    }

    /// @inheritdoc IStakingPool
    function setUnstakingPeriod(uint256 period) external override onlyOwner {
        if (period > MAX_UNSTAKING_PERIOD) revert InvalidUnstakingPeriod(period);
        uint256 oldPeriod = _unstakingPeriod;
        _unstakingPeriod = period;
        emit UnstakingPeriodUpdated(oldPeriod, period);
    }

    /**
     * @notice Authorizes or deauthorizes an address to slash agent stake
     * @param slasher The address to authorize/deauthorize
     * @param authorized Whether to authorize or deauthorize
     */
    function setAuthorizedSlasher(address slasher, bool authorized) external onlyOwner {
        if (slasher == address(0)) revert ZeroAddress();
        authorizedSlashers[slasher] = authorized;
        emit SlasherAuthorized(slasher, authorized);
    }

    /**
     * @notice Sets the treasury that receives slashed stake and unclaimable rewards
     * @param treasury_ The new treasury address
     */
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = treasury_;
        emit TreasuryUpdated(oldTreasury, treasury_);
    }

    /// @notice Pauses new stakes. Unstaking, withdrawals, rewards, and slashing keep working.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes new stakes
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _harvest(Pool storage pool, Position storage position) internal {
        if (position.shares > 0) position.pendingRewards += _accrued(pool, position.shares) - position.rewardDebt;
        position.rewardDebt = _accrued(pool, position.shares);
    }

    function _accrued(Pool storage pool, uint256 shares) internal view returns (uint256) {
        return (shares * pool.accRewardPerShare) / ACC_PRECISION;
    }

    function _sharesToAmount(Pool storage pool, uint256 shares) internal view returns (uint256) {
        if (shares == 0 || pool.totalShares == 0) return 0;
        return shares.mulDiv(pool.pooled, pool.totalShares);
    }
}
