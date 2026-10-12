// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ITreasury
 * @author Berke (pzzaworks)
 * @notice Interface for the Treasury contract
 * @dev Manages platform fee collection and distribution
 */
interface ITreasury {
    /// @notice Emitted when funds are deposited
    /// @param token The token address (address(0) for ETH)
    /// @param amount The amount deposited
    /// @param source The source of the deposit
    event Deposited(address indexed token, uint256 amount, address indexed source);

    /// @notice Emitted when funds are distributed
    /// @param token The token address
    /// @param recipient The recipient address
    /// @param amount The amount distributed
    event Distributed(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Emitted when emergency withdrawal occurs
    /// @param token The token address
    /// @param amount The amount withdrawn
    /// @param recipient The recipient address
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @notice Deposits ETH into the treasury
     */
    function deposit() external payable;

    /**
     * @notice Deposits ERC20 tokens into the treasury
     * @param token The token address
     * @param amount The amount to deposit
     */
    function depositERC20(address token, uint256 amount) external;

    /**
     * @notice Distributes funds to a recipient
     * @param token The token address (address(0) for ETH)
     * @param recipient The recipient address
     * @param amount The amount to distribute
     */
    function distribute(address token, address recipient, uint256 amount) external;

    /**
     * @notice Emergency withdrawal (owner only)
     * @param token The token address (address(0) for ETH)
     * @param amount The amount to withdraw
     * @param recipient The recipient address
     */
    function emergencyWithdraw(address token, uint256 amount, address recipient) external;

    /**
     * @notice Gets the balance of a specific token
     * @param token The token address (address(0) for ETH)
     * @return balance The token balance
     */
    function getBalance(address token) external view returns (uint256 balance);

    /**
     * @notice Gets all supported token addresses
     * @return tokens Array of token addresses
     */
    function getSupportedTokens() external view returns (address[] memory tokens);

    /**
     * @notice Adds a supported token
     * @param token The token address to add
     */
    function addSupportedToken(address token) external;

    /**
     * @notice Removes a supported token
     * @param token The token address to remove
     */
    function removeSupportedToken(address token) external;
}
