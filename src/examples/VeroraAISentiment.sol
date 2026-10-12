// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title VeroraAISentiment
 * @author Berke (pzzaworks)
 * @notice Request AI sentiment scores for assets from the Verora oracle network
 * @dev Example consumer that credits refunds of failed or cancelled requests back to each payer;
 *      the owner can only withdraw ETH that is not owed to payers
 */
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VeroraConsumer} from "../VeroraConsumer.sol";

contract VeroraAISentiment is VeroraConsumer, Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sentiment data for an asset
    struct SentimentData {
        int256 score; // -100 to 100 sentiment score
        uint256 confidence; // 0 to 100 confidence percentage
        uint256 updatedAt; // timestamp of last update
        bytes32 requestId; // the request that produced this data
    }

    /// @dev Who paid for a request and how much, so a refund can be credited back
    struct RequestPayment {
        address payer;
        uint256 amount;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Latest sentiment data per asset (keyed by asset name hash)
    mapping(bytes32 => SentimentData) public latestSentiment;

    /// @notice Maps request IDs to the asset they were querying
    mapping(bytes32 => string) private _requestAssets;

    /// @notice Payer and payment of each open request
    mapping(bytes32 => RequestPayment) private _requestPayments;

    /// @notice Refunds owed to payers of failed or cancelled requests
    mapping(address => uint256) public refunds;

    /// @notice Sum of all `refunds`, excluded from owner withdrawals
    uint256 public totalRefundsOwed;

    /// @notice Default agents to use for sentiment queries
    bytes32[] private _defaultAgents;

    /// @notice Default deadline duration (added to block.timestamp)
    uint256 public defaultDeadlineDuration = 1 hours;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SentimentRequested(bytes32 indexed requestId, string asset, address indexed requester);
    event SentimentUpdated(bytes32 indexed assetHash, string asset, int256 score, uint256 confidence);
    event SentimentUnavailable(bytes32 indexed requestId, string asset);
    event RefundCredited(bytes32 indexed requestId, address indexed payer, uint256 amount);
    event RefundWithdrawn(address indexed payer, uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NoDefaultAgents();
    error EmptyAsset();
    error ZeroAddress();
    error TransferFailed();
    error NothingToWithdraw();
    error InsufficientWithdrawable(uint256 requested, uint256 available);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the VeroraAISentiment contract
     * @param queryConsumer_ The QueryConsumer contract address
     * @param initialOwner The initial owner of the contract
     */
    constructor(address queryConsumer_, address initialOwner) VeroraConsumer(queryConsumer_) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Requests AI sentiment analysis for a given asset
     * @param asset The asset identifier (e.g., "BTC", "ETH", "SOL")
     * @return requestId The query ID
     */
    function requestSentiment(string calldata asset) external payable returns (bytes32 requestId) {
        if (bytes(asset).length == 0) revert EmptyAsset();
        if (_defaultAgents.length == 0) revert NoDefaultAgents();

        bytes memory queryData = abi.encode(asset);
        uint256 deadline = block.timestamp + defaultDeadlineDuration;

        requestId = _requestQuery("ai_sentiment", queryData, deadline, _defaultAgents);

        _requestAssets[requestId] = asset;
        _requestPayments[requestId] = RequestPayment({payer: msg.sender, amount: msg.value});

        emit SentimentRequested(requestId, asset, msg.sender);
    }

    /**
     * @notice Withdraws the caller's refunds from failed or cancelled requests
     */
    function withdrawRefund() external nonReentrant {
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        refunds[msg.sender] = 0;
        totalRefundsOwed -= amount;

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit RefundWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Gets the latest sentiment data for an asset
     * @param asset The asset identifier
     * @return data The sentiment data struct
     */
    function getSentiment(string calldata asset) external view returns (SentimentData memory data) {
        bytes32 assetHash = keccak256(abi.encodePacked(asset));
        return latestSentiment[assetHash];
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the default agents used for sentiment queries
     * @param agents The array of agent IDs
     */
    function setDefaultAgents(bytes32[] calldata agents) external onlyOwner {
        delete _defaultAgents;
        for (uint256 i = 0; i < agents.length; i++) {
            _defaultAgents.push(agents[i]);
        }
    }

    /**
     * @notice Sets the default deadline duration
     * @param duration The duration in seconds to add to block.timestamp
     */
    function setDefaultDeadlineDuration(uint256 duration) external onlyOwner {
        defaultDeadlineDuration = duration;
    }

    /**
     * @notice Cancels a sentiment request that has no responses yet and credits the payer
     * @param requestId The request to cancel
     */
    function cancelRequest(bytes32 requestId) external onlyOwner {
        _cancelRequest(requestId);
        _creditRefund(requestId);
    }

    /**
     * @notice Withdraws ETH held by this contract that is not owed to payers
     * @param recipient Where to send the ETH
     * @param amount Amount to send
     */
    function withdraw(address payable recipient, uint256 amount) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        uint256 available = balance > totalRefundsOwed ? balance - totalRefundsOwed : 0;
        if (amount > available) revert InsufficientWithdrawable(amount, available);

        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Withdrawn(recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Handles the fulfilled sentiment query result
     * @param requestId The request ID
     * @param result The ABI-encoded sentiment result (int256 score, uint256 confidence)
     */
    function _onQueryFulfilled(bytes32 requestId, bytes calldata result) internal override {
        string memory asset = _requestAssets[requestId];
        delete _requestAssets[requestId];
        delete _requestPayments[requestId];

        // Expired queries are closed with an empty result; keep the previous value
        if (result.length != 64) {
            emit SentimentUnavailable(requestId, asset);
            return;
        }

        (int256 score, uint256 confidence) = abi.decode(result, (int256, uint256));

        bytes32 assetHash = keccak256(abi.encodePacked(asset));
        latestSentiment[assetHash] =
            SentimentData({score: score, confidence: confidence, updatedAt: block.timestamp, requestId: requestId});

        emit SentimentUpdated(assetHash, asset, score, confidence);
    }

    /**
     * @notice Credits the refunded payment of a failed request to its payer
     * @param requestId The request ID
     */
    function _onQueryFailed(bytes32 requestId) internal override {
        emit SentimentUnavailable(requestId, _requestAssets[requestId]);
        _creditRefund(requestId);
    }

    /// @dev Moves a request's payment into its payer's refund balance and clears the request
    function _creditRefund(bytes32 requestId) internal {
        RequestPayment memory payment = _requestPayments[requestId];
        delete _requestPayments[requestId];
        delete _requestAssets[requestId];

        if (payment.amount == 0) return;
        refunds[payment.payer] += payment.amount;
        totalRefundsOwed += payment.amount;

        emit RefundCredited(requestId, payment.payer, payment.amount);
    }
}
