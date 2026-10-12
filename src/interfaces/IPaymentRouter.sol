// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPaymentRouter
 * @author Berke (pzzaworks)
 * @notice Interface for the Payment Router contract
 * @dev Splits query payments between the platform treasury, agent owners, and agent stakers
 */
interface IPaymentRouter {
    /// @notice Fee split configuration in basis points
    struct FeeSplit {
        uint256 platformFee;
        uint256 agentFee;
        uint256 stakerFee;
    }

    /// @notice Payment record for a (query, agent) pair
    struct PaymentInfo {
        bytes32 queryId;
        bytes32 agentId;
        address payee;
        uint256 amount;
        uint256 timestamp;
        bool processed;
    }

    event PaymentProcessed(bytes32 indexed queryId, bytes32 indexed agentId, address indexed payee, uint256 amount);
    event FeesDistributed(bytes32 indexed queryId, uint256 platformAmount, uint256 agentAmount, uint256 stakerAmount);
    event FeesWithdrawn(address indexed account, uint256 amount);

    /**
     * @notice Pays an agent for a query. Only callable by the QueryConsumer.
     */
    function processPayment(bytes32 queryId, bytes32 agentId) external payable;

    /**
     * @notice Withdraws the caller's accrued agent fees
     */
    function withdrawFees() external;

    function setFeeSplit(uint256 platformFee, uint256 agentFee, uint256 stakerFee) external;

    function getFeeSplit() external view returns (FeeSplit memory split);

    function getPaymentInfo(bytes32 queryId, bytes32 agentId) external view returns (PaymentInfo memory info);

    function getPendingFees(address account) external view returns (uint256 amount);

    /// @notice The only contract allowed to submit payments
    function queryConsumer() external view returns (address);
}
