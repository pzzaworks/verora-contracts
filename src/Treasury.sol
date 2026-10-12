// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Treasury
 * @author Berke (pzzaworks)
 * @notice Hold and distribute Verora protocol fees
 * @dev Implements ETH and allow-listed ERC20 accounting with authorized distribution and emergency withdrawal
 */
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

contract Treasury is ITreasury, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice ETH pseudo-address
    address public constant ETH_ADDRESS = address(0);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of supported ERC20 tokens
    mapping(address => bool) private _supportedTokens;

    /// @notice Array of supported token addresses
    address[] private _tokenList;

    /// @notice Mapping from token to balance
    mapping(address => uint256) private _balances;

    /// @notice Authorized distributors
    mapping(address => bool) public authorizedDistributors;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed();
    error TokenAlreadySupported(address token);
    error TokenNotSupported(address token);
    error NotAuthorizedDistributor(address caller);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event DistributorAuthorized(address indexed distributor, bool authorized);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the Treasury contract
     * @param initialOwner The initial owner of the contract
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        // ETH is always supported
        _supportedTokens[ETH_ADDRESS] = true;
        _tokenList.push(ETH_ADDRESS);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAuthorizedDistributor() {
        if (!authorizedDistributors[msg.sender] && msg.sender != owner()) revert NotAuthorizedDistributor(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ITreasury
     */
    function deposit() external payable override {
        if (msg.value == 0) revert ZeroAmount();

        _balances[ETH_ADDRESS] += msg.value;

        emit Deposited(ETH_ADDRESS, msg.value, msg.sender);
    }

    /**
     * @inheritdoc ITreasury
     */
    function depositERC20(address token, uint256 amount) external override nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!_supportedTokens[token]) revert TokenNotSupported(token);

        // Record what actually arrived, so fee-on-transfer tokens can't inflate the tracked balance
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();

        _balances[token] += received;

        emit Deposited(token, received, msg.sender);
    }

    /**
     * @inheritdoc ITreasury
     */
    function distribute(address token, address recipient, uint256 amount)
        external
        override
        nonReentrant
        onlyAuthorizedDistributor
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!_supportedTokens[token]) revert TokenNotSupported(token);
        if (_balances[token] < amount) revert InsufficientBalance(amount, _balances[token]);

        _balances[token] -= amount;

        if (token == ETH_ADDRESS) {
            (bool success,) = recipient.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }

        emit Distributed(token, recipient, amount);
    }

    /**
     * @inheritdoc ITreasury
     */
    function emergencyWithdraw(address token, uint256 amount, address recipient) external override onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 balance;
        if (token == ETH_ADDRESS) balance = address(this).balance;
        else balance = IERC20(token).balanceOf(address(this));

        uint256 withdrawAmount = amount > balance ? balance : amount;
        if (withdrawAmount == 0) revert ZeroAmount();

        _balances[token] = _balances[token] > withdrawAmount ? _balances[token] - withdrawAmount : 0;

        if (token == ETH_ADDRESS) {
            (bool success,) = recipient.call{value: withdrawAmount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, withdrawAmount);
        }

        emit EmergencyWithdrawal(token, withdrawAmount, recipient);
    }

    /**
     * @inheritdoc ITreasury
     */
    function getBalance(address token) external view override returns (uint256 balance) {
        if (token == ETH_ADDRESS) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @inheritdoc ITreasury
     */
    function getSupportedTokens() external view override returns (address[] memory tokens) {
        return _tokenList;
    }

    /**
     * @inheritdoc ITreasury
     */
    function addSupportedToken(address token) external override onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (_supportedTokens[token]) revert TokenAlreadySupported(token);

        _supportedTokens[token] = true;
        _tokenList.push(token);

        emit TokenAdded(token);
    }

    /**
     * @inheritdoc ITreasury
     */
    function removeSupportedToken(address token) external override onlyOwner {
        if (token == ETH_ADDRESS) revert TokenNotSupported(token); // Can't remove ETH
        if (!_supportedTokens[token]) revert TokenNotSupported(token);

        _supportedTokens[token] = false;

        // Remove from token list
        for (uint256 i = 0; i < _tokenList.length; i++) {
            if (_tokenList[i] == token) {
                _tokenList[i] = _tokenList[_tokenList.length - 1];
                _tokenList.pop();
                break;
            }
        }

        emit TokenRemoved(token);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes or deauthorizes a distributor
     * @param distributor The address to authorize/deauthorize
     * @param authorized Whether to authorize or deauthorize
     */
    function setAuthorizedDistributor(address distributor, bool authorized) external onlyOwner {
        if (distributor == address(0)) revert ZeroAddress();
        authorizedDistributors[distributor] = authorized;
        emit DistributorAuthorized(distributor, authorized);
    }

    /**
     * @notice Checks if a token is supported
     * @param token The token address
     * @return True if supported
     */
    function isTokenSupported(address token) external view returns (bool) {
        return _supportedTokens[token];
    }

    /**
     * @notice Gets the tracked balance for a token
     * @param token The token address
     * @return The tracked balance
     */
    function getTrackedBalance(address token) external view returns (uint256) {
        return _balances[token];
    }

    /// @notice Receive function to accept ETH
    receive() external payable {
        _balances[ETH_ADDRESS] += msg.value;
        emit Deposited(ETH_ADDRESS, msg.value, msg.sender);
    }
}
