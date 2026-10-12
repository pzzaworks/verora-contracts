// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title PaymentRouter
 * @author Berke (pzzaworks)
 * @notice Route settled query payments to agents, stakers, and the treasury
 * @dev Implements bounded fee splits with pull payments for agents and fail-safe treasury and staker pushes.
 *      Only the QueryConsumer can submit payments, so nobody can pre-pay a (query, agent) pair and block
 *      finalization.
 */
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";

contract PaymentRouter is IPaymentRouter, Ownable2Step, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_BPS = 10_000;

    /// @notice Fee split bounds, so the owner can't redirect agent earnings to the platform
    uint256 public constant MAX_PLATFORM_FEE = 2000;
    uint256 public constant MAX_STAKER_FEE = 3000;
    uint256 public constant MIN_AGENT_FEE = 5000;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    IAgentRegistry public immutable agentRegistry;
    IStakingPool public stakingPool;
    address public treasury;
    address public queryConsumer;

    FeeSplit private _feeSplit;

    mapping(bytes32 => PaymentInfo) private _payments;

    /// @dev Pull balances for agent owners
    mapping(address => uint256) private _pendingFees;

    /// @notice Platform fees whose push to the treasury failed; flushed to the current treasury
    uint256 public pendingTreasuryFees;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotQueryConsumer(address caller);
    error QueryAlreadyPaid(bytes32 queryId, bytes32 agentId);
    error InvalidFeeSplit();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();
    error NothingToWithdraw();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeeSplitUpdated(uint256 platformFee, uint256 agentFee, uint256 stakerFee);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event StakingPoolUpdated(address oldPool, address newPool);
    event QueryConsumerUpdated(address oldConsumer, address newConsumer);
    event TreasuryFeesFlushed(address indexed treasury, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the PaymentRouter contract
     * @param initialOwner The initial owner of the contract
     * @param agentRegistry_ The AgentRegistry contract address
     * @param stakingPool_ The StakingPool contract address
     * @param treasury_ The Treasury address
     */
    constructor(address initialOwner, address agentRegistry_, address stakingPool_, address treasury_)
        Ownable(initialOwner)
    {
        if (agentRegistry_ == address(0) || stakingPool_ == address(0) || treasury_ == address(0)) revert ZeroAddress();

        agentRegistry = IAgentRegistry(agentRegistry_);
        stakingPool = IStakingPool(stakingPool_);
        treasury = treasury_;

        // Default split: 10% platform, 80% agent, 10% stakers
        _feeSplit = FeeSplit({platformFee: 1000, agentFee: 8000, stakerFee: 1000});
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPaymentRouter
    function processPayment(bytes32 queryId, bytes32 agentId) external payable override nonReentrant {
        if (msg.sender != queryConsumer) revert NotQueryConsumer(msg.sender);
        if (msg.value == 0) revert ZeroAmount();

        bytes32 paymentId = keccak256(abi.encodePacked(queryId, agentId));
        if (_payments[paymentId].processed) revert QueryAlreadyPaid(queryId, agentId);

        // Reverts for unknown agents; inactive agents are still paid for work already delivered
        address payee = agentRegistry.getAgent(agentId).owner;

        _payments[paymentId] = PaymentInfo({
            queryId: queryId,
            agentId: agentId,
            payee: payee,
            amount: msg.value,
            timestamp: block.timestamp,
            processed: true
        });

        _distributeFees(queryId, agentId, payee, msg.value);

        emit PaymentProcessed(queryId, agentId, payee, msg.value);
    }

    /// @inheritdoc IPaymentRouter
    function withdrawFees() external override nonReentrant {
        uint256 amount = _pendingFees[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        _pendingFees[msg.sender] = 0;

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit FeesWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Pushes treasury fees whose direct transfer failed. Permissionless.
     */
    function flushTreasuryFees() external nonReentrant {
        uint256 amount = pendingTreasuryFees;
        if (amount == 0) revert NothingToWithdraw();

        pendingTreasuryFees = 0;

        (bool success,) = treasury.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit TreasuryFeesFlushed(treasury, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPaymentRouter
    function getFeeSplit() external view override returns (FeeSplit memory split) {
        return _feeSplit;
    }

    /// @inheritdoc IPaymentRouter
    function getPaymentInfo(bytes32 queryId, bytes32 agentId)
        external
        view
        override
        returns (PaymentInfo memory info)
    {
        return _payments[keccak256(abi.encodePacked(queryId, agentId))];
    }

    /// @inheritdoc IPaymentRouter
    function getPendingFees(address account) external view override returns (uint256 amount) {
        return _pendingFees[account];
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPaymentRouter
    function setFeeSplit(uint256 platformFee, uint256 agentFee, uint256 stakerFee) external override onlyOwner {
        if (platformFee + agentFee + stakerFee != MAX_BPS) revert InvalidFeeSplit();
        if (platformFee > MAX_PLATFORM_FEE || stakerFee > MAX_STAKER_FEE || agentFee < MIN_AGENT_FEE) {
            revert InvalidFeeSplit();
        }

        _feeSplit = FeeSplit({platformFee: platformFee, agentFee: agentFee, stakerFee: stakerFee});
        emit FeeSplitUpdated(platformFee, agentFee, stakerFee);
    }

    /**
     * @notice Sets the only contract allowed to submit payments
     * @param queryConsumer_ The QueryConsumer address
     */
    function setQueryConsumer(address queryConsumer_) external onlyOwner {
        if (queryConsumer_ == address(0)) revert ZeroAddress();
        address oldConsumer = queryConsumer;
        queryConsumer = queryConsumer_;
        emit QueryConsumerUpdated(oldConsumer, queryConsumer_);
    }

    /**
     * @notice Sets the treasury that receives the platform share
     * @dev Fees credited to the previous treasury are flushed to the new one
     * @param treasury_ The new treasury address
     */
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = treasury_;
        emit TreasuryUpdated(oldTreasury, treasury_);
    }

    /**
     * @notice Sets the staking pool that receives the staker share
     * @param stakingPool_ The new StakingPool address
     */
    function setStakingPool(address stakingPool_) external onlyOwner {
        if (stakingPool_ == address(0)) revert ZeroAddress();
        address oldPool = address(stakingPool);
        stakingPool = IStakingPool(stakingPool_);
        emit StakingPoolUpdated(oldPool, stakingPool_);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Splits a payment. External transfers never revert the whole payment: a failed treasury push
     *      is credited (flushable) and a failed staker distribution falls back to the treasury.
     */
    function _distributeFees(bytes32 queryId, bytes32 agentId, address payee, uint256 amount) internal {
        uint256 platformAmount = (amount * _feeSplit.platformFee) / MAX_BPS;
        uint256 stakerAmount = (amount * _feeSplit.stakerFee) / MAX_BPS;
        uint256 agentAmount = amount - platformAmount - stakerAmount;

        _pendingFees[payee] += agentAmount;

        if (stakerAmount > 0) {
            try stakingPool.distributeRewards{value: stakerAmount}(agentId) {}
            catch {
                platformAmount += stakerAmount;
                stakerAmount = 0;
            }
        }

        if (platformAmount > 0) {
            (bool success,) = treasury.call{value: platformAmount}("");
            if (!success) pendingTreasuryFees += platformAmount;
        }

        emit FeesDistributed(queryId, platformAmount, agentAmount, stakerAmount);
    }
}
