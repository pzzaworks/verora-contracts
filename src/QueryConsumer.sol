// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title QueryConsumer
 * @author Berke (pzzaworks)
 * @notice Escrows query payments and settles agent responses into payments and reputation
 * @dev Implements request-bound signed responses, finalizer-validated settlement, and griefing-resistant expiry.
 *      Escrow exits (finalize, expiry, cancel) only require agents to exist, never to be active, so a suspended
 *      or slashed agent can't lock requester funds. Every query lasts at least `minQueryDuration`, and expired
 *      queries without responses are refunded in full. Settlement and record keeping run in the linked
 *      QuerySettlement and QueryBook libraries, which document the reputation rules.
 */
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IQueryConsumer} from "./interfaces/IQueryConsumer.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {IReputationManager} from "./interfaces/IReputationManager.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {QueryBook} from "./libraries/QueryBook.sol";
import {QuerySettlement} from "./libraries/QuerySettlement.sol";

contract QueryConsumer is IQueryConsumer, IERC5267, Ownable2Step, Pausable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum accepted responses for a query to complete
    uint256 public constant MIN_RESPONSES = QuerySettlement.MIN_RESPONSES;

    /// @notice Upper bound on agents per query (bounds every per-query loop)
    uint256 public constant MAX_AGENTS_PER_QUERY = QueryBook.MAX_AGENTS_PER_QUERY;

    /// @notice Longest allowed query lifetime, so escrow can't be locked indefinitely
    uint256 public constant MAX_QUERY_DURATION = QueryBook.MAX_QUERY_DURATION;

    /// @notice Bounds for the owner-configurable minimum query duration
    uint256 public constant MIN_QUERY_DURATION_FLOOR = 1 minutes;
    uint256 public constant MIN_QUERY_DURATION_CEILING = 1 days;

    /// @notice Time after the deadline reserved for the finalizer before anyone can close a query with responses
    uint256 public constant FINALIZATION_GRACE_PERIOD = QuerySettlement.FINALIZATION_GRACE_PERIOD;

    /// @notice Size limits for on-chain payloads
    uint256 public constant MAX_QUERY_DATA_LENGTH = QueryBook.MAX_QUERY_DATA_LENGTH;
    uint256 public constant MAX_RESPONSE_DATA_LENGTH = QueryBook.MAX_RESPONSE_DATA_LENGTH;
    uint256 public constant MAX_QUERY_TYPE_LENGTH = QueryBook.MAX_QUERY_TYPE_LENGTH;

    /// @notice Hard ceiling for the consumer callback gas limit
    uint256 public constant MAX_CALLBACK_GAS_LIMIT = 2_000_000;

    /// @notice Callback revert data copied into `CallbackFailed` (longer reasons are truncated)
    uint256 public constant MAX_CALLBACK_REASON_LENGTH = QuerySettlement.MAX_CALLBACK_REASON_LENGTH;

    /// @notice Gas forwarded with pushed refunds; a failed push is credited for `withdrawRefund`
    uint256 public constant REFUND_GAS_LIMIT = QuerySettlement.REFUND_GAS_LIMIT;

    /// @notice EIP-712 domain name and version agents sign under
    string private constant EIP712_NAME = "Verora QueryConsumer";
    string private constant EIP712_VERSION = "1";

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice EIP-712 typehash for relayed agent responses, bound to the stored request
    bytes32 public constant RESPONSE_TYPEHASH = keccak256(
        "Response(bytes32 queryId,bytes32 agentId,bytes32 queryTypeHash,bytes32 queryDataHash,bytes32 responseHash)"
    );

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    IAgentRegistry public immutable agentRegistry;

    /// @dev Domain separator cached for the deployment chain; rebuilt on a chain fork
    bytes32 private immutable _cachedDomainSeparator;
    uint256 private immutable _cachedChainId;
    IReputationManager public reputationManager;
    IPaymentRouter public paymentRouter;

    mapping(bytes32 => QueryInfo) private _queries;
    mapping(bytes32 => QueryBook.RequestHashes) private _requestHashes;
    mapping(bytes32 => ResponseInfo[]) private _responses;
    mapping(bytes32 => bytes) private _aggregatedResults;
    mapping(bytes32 => mapping(bytes32 => bool)) private _hasResponded;
    mapping(bytes32 => mapping(bytes32 => bool)) private _isAssigned;
    mapping(address => bytes32[]) private _requesterQueries;

    /// @dev Pending queries per agent, with 1-based positions for O(1) removal
    mapping(bytes32 => bytes32[]) private _agentPendingQueries;
    mapping(bytes32 => mapping(bytes32 => uint256)) private _pendingPosition;

    /// @dev Refunds that could not be pushed to the requester
    mapping(address => uint256) private _pendingRefunds;

    uint256 private _queryNonce;

    mapping(address => bool) public authorizedFinalizers;

    /// @notice Gas forwarded to consumer contract callbacks
    uint256 public callbackGasLimit = 500_000;

    /// @notice Minimum payment per assigned agent (anti-spam)
    uint256 public minPaymentPerAgent;

    /// @notice Shortest allowed time between query creation and its deadline
    uint256 public minQueryDuration = 5 minutes;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event FinalizerAuthorized(address indexed finalizer, bool authorized);
    event ReputationManagerUpdated(address oldManager, address newManager);
    event PaymentRouterUpdated(address oldRouter, address newRouter);
    event CallbackGasLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event MinPaymentPerAgentUpdated(uint256 oldMinimum, uint256 newMinimum);
    event MinQueryDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event RefundWithdrawn(address indexed requester, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the QueryConsumer contract
     * @param initialOwner The initial owner of the contract
     * @param agentRegistry_ The AgentRegistry contract address
     * @param reputationManager_ The ReputationManager contract address
     * @param paymentRouter_ The PaymentRouter contract address
     * @param minPaymentPerAgent_ Minimum payment per assigned agent, in wei
     */
    constructor(
        address initialOwner,
        address agentRegistry_,
        address reputationManager_,
        address paymentRouter_,
        uint256 minPaymentPerAgent_
    ) Ownable(initialOwner) {
        if (agentRegistry_ == address(0) || reputationManager_ == address(0) || paymentRouter_ == address(0)) {
            revert ZeroAddress();
        }

        agentRegistry = IAgentRegistry(agentRegistry_);
        reputationManager = IReputationManager(reputationManager_);
        paymentRouter = IPaymentRouter(paymentRouter_);
        minPaymentPerAgent = minPaymentPerAgent_;
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAuthorizedFinalizer() {
        if (!authorizedFinalizers[msg.sender] && msg.sender != owner()) revert NotAuthorizedFinalizer(msg.sender);
        _;
    }

    modifier queryExists(bytes32 queryId) {
        if (_queries[queryId].queryId == bytes32(0)) revert QueryNotFound(queryId);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IQueryConsumer
    function createQuery(
        string calldata queryType,
        bytes calldata queryData,
        uint256 deadline,
        bytes32[] calldata agents
    ) external payable override nonReentrant whenNotPaused returns (bytes32 queryId) {
        queryId = keccak256(abi.encodePacked(msg.sender, block.timestamp, _queryNonce++));

        QueryBook.create(
            QueryBook.CreateConfig({
                queryId: queryId,
                requester: msg.sender,
                payment: msg.value,
                agentRegistry: agentRegistry,
                minQueryDuration: minQueryDuration,
                minPaymentPerAgent: minPaymentPerAgent
            }),
            _queries,
            _requestHashes,
            _requesterQueries,
            _isAssigned[queryId],
            _agentPendingQueries,
            _pendingPosition,
            queryType,
            queryData,
            deadline,
            agents
        );
    }

    /// @inheritdoc IQueryConsumer
    function submitResponse(bytes32 queryId, bytes32 agentId, bytes calldata responseData)
        external
        override
        nonReentrant
        queryExists(queryId)
    {
        address agentOwner = QueryBook.agentOwner(agentRegistry, agentId);
        if (agentOwner != msg.sender) revert NotAgentOwner(agentId, msg.sender);

        _recordResponse(queryId, agentId, responseData);
    }

    /// @inheritdoc IQueryConsumer
    function submitResponseFor(bytes32 queryId, bytes32 agentId, bytes calldata responseData, bytes calldata signature)
        external
        override
        nonReentrant
        queryExists(queryId)
    {
        QueryBook.verifyAgentSignature(
            agentRegistry, agentId, _responseDigest(queryId, agentId, responseData), signature
        );

        _recordResponse(queryId, agentId, responseData);
    }

    /// @inheritdoc IQueryConsumer
    function finalizeQuery(bytes32 queryId, bytes calldata aggregatedResult, bytes32[] calldata acceptedAgents)
        external
        override
        nonReentrant
        queryExists(queryId)
        onlyAuthorizedFinalizer
    {
        QuerySettlement.finalize(
            _context(queryId),
            _queries[queryId],
            _responses[queryId],
            _hasResponded[queryId],
            _agentPendingQueries,
            _pendingPosition,
            _pendingRefunds,
            _aggregatedResults,
            aggregatedResult,
            acceptedAgents
        );
    }

    /// @inheritdoc IQueryConsumer
    function failExpiredQuery(bytes32 queryId) external override nonReentrant queryExists(queryId) {
        QuerySettlement.expire(
            _context(queryId),
            _queries[queryId],
            _responses[queryId],
            _hasResponded[queryId],
            _agentPendingQueries,
            _pendingPosition,
            _pendingRefunds
        );
    }

    /// @inheritdoc IQueryConsumer
    function cancelQuery(bytes32 queryId) external override nonReentrant queryExists(queryId) {
        QuerySettlement.cancel(queryId, _queries[queryId], _agentPendingQueries, _pendingPosition, _pendingRefunds);
    }

    /// @inheritdoc IQueryConsumer
    function withdrawRefund() external override nonReentrant {
        uint256 amount = _pendingRefunds[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        _pendingRefunds[msg.sender] = 0;

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit RefundWithdrawn(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IQueryConsumer
    function getQuery(bytes32 queryId) external view override returns (QueryInfo memory info) {
        if (_queries[queryId].queryId == bytes32(0)) revert QueryNotFound(queryId);
        return _queries[queryId];
    }

    /// @inheritdoc IQueryConsumer
    function getResponses(bytes32 queryId) external view override returns (ResponseInfo[] memory responses) {
        return _responses[queryId];
    }

    /// @inheritdoc IQueryConsumer
    function getAggregatedResult(bytes32 queryId) external view override returns (bytes memory result) {
        return _aggregatedResults[queryId];
    }

    /// @inheritdoc IQueryConsumer
    function getQueriesByRequester(address requester) external view override returns (bytes32[] memory queryIds) {
        return _requesterQueries[requester];
    }

    /// @inheritdoc IQueryConsumer
    function getPendingQueriesForAgent(bytes32 agentId, uint256 offset, uint256 limit)
        external
        view
        override
        returns (bytes32[] memory queryIds)
    {
        bytes32[] storage pending = _agentPendingQueries[agentId];
        uint256 total = pending.length;
        if (offset >= total) return new bytes32[](0);

        uint256 end = limit > total - offset ? total : offset + limit;
        queryIds = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            queryIds[i - offset] = pending[i];
        }
    }

    /// @inheritdoc IQueryConsumer
    function getPendingQueryCount(bytes32 agentId) external view override returns (uint256 count) {
        return _agentPendingQueries[agentId].length;
    }

    /// @inheritdoc IQueryConsumer
    function getPendingRefund(address requester) external view override returns (uint256 amount) {
        return _pendingRefunds[requester];
    }

    /// @inheritdoc IQueryConsumer
    function responseDigest(bytes32 queryId, bytes32 agentId, bytes calldata responseData)
        external
        view
        override
        queryExists(queryId)
        returns (bytes32 digest)
    {
        return _responseDigest(queryId, agentId, responseData);
    }

    /// @inheritdoc IERC5267
    function eip712Domain()
        external
        view
        override
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", EIP712_NAME, EIP712_VERSION, block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes or deauthorizes an oracle to finalize queries
     * @param finalizer The oracle address
     * @param authorized Whether the address may finalize
     */
    function setAuthorizedFinalizer(address finalizer, bool authorized) external onlyOwner {
        if (finalizer == address(0)) revert ZeroAddress();
        authorizedFinalizers[finalizer] = authorized;
        emit FinalizerAuthorized(finalizer, authorized);
    }

    /**
     * @notice Points reputation recording at a new ReputationManager
     * @dev The new manager must authorize this contract as a recorder before queries settle
     * @param reputationManager_ The new ReputationManager address
     */
    function setReputationManager(address reputationManager_) external onlyOwner {
        if (reputationManager_ == address(0)) revert ZeroAddress();
        address oldManager = address(reputationManager);
        reputationManager = IReputationManager(reputationManager_);
        emit ReputationManagerUpdated(oldManager, reputationManager_);
    }

    /**
     * @notice Points settlement payments at a new PaymentRouter
     * @dev Reverts unless the router already accepts payments from this contract, so settlement can't brick
     * @param paymentRouter_ The new PaymentRouter address
     */
    function setPaymentRouter(address paymentRouter_) external onlyOwner {
        if (paymentRouter_ == address(0)) revert ZeroAddress();
        if (IPaymentRouter(paymentRouter_).queryConsumer() != address(this)) {
            revert PaymentRouterMismatch(paymentRouter_);
        }
        address oldRouter = address(paymentRouter);
        paymentRouter = IPaymentRouter(paymentRouter_);
        emit PaymentRouterUpdated(oldRouter, paymentRouter_);
    }

    /**
     * @notice Sets the gas forwarded to consumer contract callbacks
     * @param gasLimit The new limit, between 1 and `MAX_CALLBACK_GAS_LIMIT`
     */
    function setCallbackGasLimit(uint256 gasLimit) external onlyOwner {
        if (gasLimit == 0 || gasLimit > MAX_CALLBACK_GAS_LIMIT) revert InvalidCallbackGasLimit(gasLimit);
        uint256 oldLimit = callbackGasLimit;
        callbackGasLimit = gasLimit;
        emit CallbackGasLimitUpdated(oldLimit, gasLimit);
    }

    /**
     * @notice Sets the minimum payment required per assigned agent
     * @param minimum The new minimum, in wei
     */
    function setMinPaymentPerAgent(uint256 minimum) external onlyOwner {
        uint256 oldMinimum = minPaymentPerAgent;
        minPaymentPerAgent = minimum;
        emit MinPaymentPerAgentUpdated(oldMinimum, minimum);
    }

    /**
     * @notice Sets the shortest allowed query window
     * @dev Raising it also stops failures from being recorded for open queries with a shorter window
     * @param duration The new minimum, between `MIN_QUERY_DURATION_FLOOR` and `MIN_QUERY_DURATION_CEILING`
     */
    function setMinQueryDuration(uint256 duration) external onlyOwner {
        if (duration < MIN_QUERY_DURATION_FLOOR || duration > MIN_QUERY_DURATION_CEILING) {
            revert InvalidMinQueryDuration(duration);
        }
        uint256 oldDuration = minQueryDuration;
        minQueryDuration = duration;
        emit MinQueryDurationUpdated(oldDuration, duration);
    }

    /// @notice Pauses query creation. Responses, finalization, expiry, and refunds keep working.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes query creation
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _recordResponse(bytes32 queryId, bytes32 agentId, bytes calldata responseData) internal {
        QueryBook.recordResponse(
            _queries[queryId],
            _responses[queryId],
            _isAssigned[queryId],
            _hasResponded[queryId],
            queryId,
            agentId,
            responseData
        );
    }

    /// @dev Settlement context for the linked QuerySettlement library, which runs in this contract's context
    function _context(bytes32 queryId) private view returns (QuerySettlement.Context memory) {
        return QuerySettlement.Context({
            queryId: queryId,
            agentRegistry: agentRegistry,
            reputationManager: reputationManager,
            paymentRouter: paymentRouter,
            minQueryDuration: minQueryDuration,
            callbackGasLimit: callbackGasLimit
        });
    }

    /// @dev EIP-712 domain separator for the current chain
    function _domainSeparatorV4() internal view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_NAME)),
                keccak256(bytes(EIP712_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    function _responseDigest(bytes32 queryId, bytes32 agentId, bytes calldata responseData)
        internal
        view
        returns (bytes32)
    {
        QueryBook.RequestHashes storage request = _requestHashes[queryId];
        return MessageHashUtils.toTypedDataHash(
            _domainSeparatorV4(),
            keccak256(
                abi.encode(
                    RESPONSE_TYPEHASH,
                    queryId,
                    agentId,
                    request.queryTypeHash,
                    request.queryDataHash,
                    keccak256(responseData)
                )
            )
        );
    }
}
