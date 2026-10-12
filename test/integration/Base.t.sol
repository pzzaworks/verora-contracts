// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentRegistry} from "../../src/AgentRegistry.sol";
import {ReputationManager} from "../../src/ReputationManager.sol";
import {StakingPool} from "../../src/StakingPool.sol";
import {PaymentRouter} from "../../src/PaymentRouter.sol";
import {QueryConsumer} from "../../src/QueryConsumer.sol";
import {Treasury} from "../../src/Treasury.sol";
import {IQueryConsumer} from "../../src/interfaces/IQueryConsumer.sol";
import {IReputationManager} from "../../src/interfaces/IReputationManager.sol";
import {IStakingPool} from "../../src/interfaces/IStakingPool.sol";

/**
 * @title IntegrationBase
 * @author Berke (pzzaworks)
 * @notice Base contract for integration tests with full contract deployment
 * @dev Deploys all Verora contracts and sets up proper authorizations
 */
abstract contract IntegrationBase is Test {
    /*//////////////////////////////////////////////////////////////
                              CONTRACTS
    //////////////////////////////////////////////////////////////*/

    Treasury public treasury;
    AgentRegistry public registry;
    StakingPool public staking;
    ReputationManager public reputation;
    PaymentRouter public payment;
    QueryConsumer public query;

    /*//////////////////////////////////////////////////////////////
                            TEST ACCOUNTS
    //////////////////////////////////////////////////////////////*/

    address public deployer;
    address public alice;
    uint256 public aliceKey;
    uint256 public bobKey;
    address public bob;
    address public charlie;
    address public requester;
    address public finalizer;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MINIMUM_STAKE = 0.1 ether;
    uint256 public constant UNSTAKING_PERIOD = 7 days;
    uint256 public constant MIN_PAYMENT_PER_AGENT = 0.0001 ether;

    string public constant ENDPOINT_ALICE = "http://localhost:4000";
    string public constant ENDPOINT_BOB = "http://localhost:4001";
    string public constant ENDPOINT_CHARLIE = "http://localhost:4002";
    bytes public constant ATTESTATION = hex"1234567890abcdef";

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // Create test accounts
        deployer = makeAddr("deployer");
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        charlie = makeAddr("charlie");
        requester = makeAddr("requester");
        finalizer = makeAddr("finalizer");

        // Fund accounts
        vm.deal(deployer, 1000 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(requester, 100 ether);

        // Deploy contracts as deployer
        vm.startPrank(deployer);

        // 1. Deploy Treasury (no dependencies)
        treasury = new Treasury(deployer);

        // 2. Deploy AgentRegistry (no dependencies)
        registry = new AgentRegistry(deployer);

        // 3. Deploy StakingPool (depends on AgentRegistry, Treasury)
        staking = new StakingPool(deployer, address(registry), address(treasury), MINIMUM_STAKE, UNSTAKING_PERIOD);

        // 4. Deploy ReputationManager (depends on AgentRegistry)
        reputation = new ReputationManager(deployer, address(registry));

        // 5. Deploy PaymentRouter (depends on AgentRegistry, StakingPool, Treasury)
        payment = new PaymentRouter(deployer, address(registry), address(staking), address(treasury));

        // 6. Deploy QueryConsumer (depends on AgentRegistry, ReputationManager, PaymentRouter)
        query =
            new QueryConsumer(deployer, address(registry), address(reputation), address(payment), MIN_PAYMENT_PER_AGENT);

        // Setup authorizations
        registry.setAuthorizedSlasher(address(staking), true);
        reputation.setAuthorizedRecorder(address(query), true);
        payment.setQueryConsumer(address(query));
        query.setAuthorizedFinalizer(finalizer, true);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a string array with given capabilities
     */
    function _capabilities(string memory cap1) internal pure returns (string[] memory) {
        string[] memory caps = new string[](1);
        caps[0] = cap1;
        return caps;
    }

    function _capabilities(string memory cap1, string memory cap2) internal pure returns (string[] memory) {
        string[] memory caps = new string[](2);
        caps[0] = cap1;
        caps[1] = cap2;
        return caps;
    }

    /**
     * @notice Registers an agent with default settings
     */
    function _registerAgent(address owner, string memory endpoint) internal returns (bytes32) {
        vm.prank(owner);
        return registry.registerAgent(endpoint, _capabilities("price_feed"), ATTESTATION, "");
    }

    /**
     * @notice Registers and stakes for an agent
     */
    function _registerAndStake(address owner, string memory endpoint, uint256 stakeAmount)
        internal
        returns (bytes32 agentId)
    {
        vm.startPrank(owner);
        agentId = registry.registerAgent(endpoint, _capabilities("price_feed"), ATTESTATION, "");
        staking.stake{value: stakeAmount}(agentId);
        vm.stopPrank();
    }

    /**
     * @notice Creates a query with given parameters
     */
    function _createQuery(address sender, bytes32[] memory agents, uint256 paymentAmount, uint256 deadline)
        internal
        returns (bytes32)
    {
        vm.prank(sender);
        return query.createQuery{value: paymentAmount}("price_feed", abi.encode("ETH/USD"), deadline, agents);
    }

    /**
     * @notice Creates a single-agent query
     */
    function _createSingleAgentQuery(address sender, bytes32 agentId, uint256 paymentAmount)
        internal
        returns (bytes32)
    {
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentId;
        return _createQuery(sender, agents, paymentAmount, block.timestamp + 1 hours);
    }

    /**
     * @notice Submit response as agent owner
     */
    function _submitResponse(address agentOwner, bytes32 queryId, bytes32 agentId, uint256 priceValue) internal {
        vm.prank(agentOwner);
        query.submitResponse(queryId, agentId, abi.encode(priceValue));
    }

    /**
     * @notice Finalize query, accepting every response
     */
    function _finalizeQuery(bytes32 queryId, uint256 aggregatedValue) internal {
        bytes32[] memory accepted = _responders(queryId);
        vm.prank(finalizer);
        query.finalizeQuery(queryId, abi.encode(aggregatedValue), accepted);
    }

    /**
     * @notice Every agent that responded to a query, i.e. the finalizer accepting all responses
     */
    function _responders(bytes32 queryId) internal view returns (bytes32[] memory agentIds) {
        IQueryConsumer.ResponseInfo[] memory responses = query.getResponses(queryId);
        agentIds = new bytes32[](responses.length);
        for (uint256 i = 0; i < responses.length; i++) {
            agentIds[i] = responses[i].agentId;
        }
    }

    /**
     * @notice Get agent reputation score
     */
    function _getReputation(bytes32 agentId) internal view returns (uint256) {
        return reputation.getReputation(agentId);
    }

    /**
     * @notice Get agent query stats
     */
    function _getQueryStats(bytes32 agentId) internal view returns (IReputationManager.QueryStats memory) {
        return reputation.getQueryStats(agentId);
    }

    /**
     * @notice Get stake info for an agent
     */
    function _getStake(bytes32 agentId, address staker) internal view returns (IStakingPool.StakeInfo memory) {
        return staking.getStake(agentId, staker);
    }

    /**
     * @notice Signs an EIP-712 response authorization with an agent owner's key
     */
    function _signResponse(uint256 ownerKey, bytes32 queryId, bytes32 agentId, bytes memory responseData)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = query.responseDigest(queryId, agentId, responseData);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
