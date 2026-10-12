// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReputationManager} from "../src/ReputationManager.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {IReputationManager} from "../src/interfaces/IReputationManager.sol";

contract ReputationManagerTest is Test {
    ReputationManager public reputationManager;
    AgentRegistry public registry;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public recorder = makeAddr("recorder");

    bytes32 public agentId;

    string public constant ENDPOINT = "https://agent.verora.io";
    string[] public capabilities;
    bytes public constant ATTESTATION = hex"1234567890";

    event ReputationUpdated(bytes32 indexed agentId, uint256 newReputation, uint256 totalQueries);
    event QueryRecorded(bytes32 indexed agentId, bytes32 indexed queryId, bool success);
    event RecorderAuthorized(address indexed recorder, bool authorized);
    event DecayFactorUpdated(uint256 oldFactor, uint256 newFactor);

    function setUp() public {
        registry = new AgentRegistry(owner);
        reputationManager = new ReputationManager(owner, address(registry));

        capabilities.push("price_feed");

        vm.prank(alice);
        agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        reputationManager.setAuthorizedRecorder(recorder, true);
    }

    /*//////////////////////////////////////////////////////////////
                          SUCCESS RECORDING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RecordSuccess() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(recorder);
        reputationManager.recordSuccess(agentId, queryId);

        IReputationManager.QueryStats memory stats = reputationManager.getQueryStats(agentId);
        assertEq(stats.totalQueries, 1);
        assertEq(stats.successfulQueries, 1);
        assertEq(stats.failedQueries, 0);
        assertEq(stats.lastQueryTimestamp, block.timestamp);
    }

    function test_RecordSuccess_EmitsEvents() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(recorder);
        vm.expectEmit(true, true, false, true);
        emit QueryRecorded(agentId, queryId, true);
        reputationManager.recordSuccess(agentId, queryId);
    }

    function test_RecordSuccess_RevertOnDuplicateQuery() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(recorder);
        reputationManager.recordSuccess(agentId, queryId);

        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(ReputationManager.QueryAlreadyRecorded.selector, queryId));
        reputationManager.recordSuccess(agentId, queryId);
    }

    function test_RecordSuccess_RevertOnUnauthorized() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReputationManager.NotAuthorizedRecorder.selector, alice));
        reputationManager.recordSuccess(agentId, queryId);
    }

    /// @dev Outcomes must stay recordable for suspended agents so query settlement can't be blocked
    function test_RecordSuccess_WorksForSuspendedAgent() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(alice);
        registry.suspendAgent(agentId, "Testing");

        vm.prank(recorder);
        reputationManager.recordSuccess(agentId, queryId);
        assertEq(reputationManager.getQueryStats(agentId).successfulQueries, 1);
    }

    function test_RecordSuccess_RevertOnUnknownAgent() public {
        bytes32 unknown = keccak256("unknown");

        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(ReputationManager.AgentNotFound.selector, unknown));
        reputationManager.recordSuccess(unknown, keccak256("query1"));
    }

    /*//////////////////////////////////////////////////////////////
                          FAILURE RECORDING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RecordFailure() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(recorder);
        reputationManager.recordFailure(agentId, queryId);

        IReputationManager.QueryStats memory stats = reputationManager.getQueryStats(agentId);
        assertEq(stats.totalQueries, 1);
        assertEq(stats.successfulQueries, 0);
        assertEq(stats.failedQueries, 1);
    }

    function test_RecordFailure_EmitsEvents() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(recorder);
        vm.expectEmit(true, true, false, true);
        emit QueryRecorded(agentId, queryId, false);
        reputationManager.recordFailure(agentId, queryId);
    }

    /*//////////////////////////////////////////////////////////////
                          REPUTATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetReputation_InitialValue() public view {
        uint256 reputation = reputationManager.getReputation(agentId);
        assertEq(reputation, 5000); // INITIAL_REPUTATION
    }

    function test_GetReputation_AfterSuccess() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(recorder);
        reputationManager.recordSuccess(agentId, queryId);

        uint256 reputation = reputationManager.getReputation(agentId);
        assertEq(reputation, 10_000); // 100% success rate
    }

    function test_GetReputation_AfterFailure() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(recorder);
        reputationManager.recordFailure(agentId, queryId);

        uint256 reputation = reputationManager.getReputation(agentId);
        assertEq(reputation, 0); // 0% success rate
    }

    function test_GetReputation_Mixed() public {
        // Record 3 successes and 1 failure
        vm.startPrank(recorder);
        reputationManager.recordSuccess(agentId, keccak256("query1"));
        reputationManager.recordSuccess(agentId, keccak256("query2"));
        reputationManager.recordSuccess(agentId, keccak256("query3"));
        reputationManager.recordFailure(agentId, keccak256("query4"));
        vm.stopPrank();

        uint256 reputation = reputationManager.getReputation(agentId);
        assertEq(reputation, 7500); // 75% success rate
    }

    function test_GetReputation_WithDecay() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(recorder);
        reputationManager.recordSuccess(agentId, queryId);

        // Fast forward past decay period
        vm.warp(block.timestamp + 31 days);

        uint256 reputation = reputationManager.getReputation(agentId);
        // Should be less than 10000 due to decay
        assertLt(reputation, 10_000);
        // 5% decay: 10000 - 500 = 9500
        assertEq(reputation, 9500);
    }

    function test_GetReputation_MultipleDecayPeriods() public {
        bytes32 queryId = keccak256("query1");

        vm.prank(recorder);
        reputationManager.recordSuccess(agentId, queryId);

        // Fast forward 90 days (3 decay periods)
        vm.warp(block.timestamp + 90 days);

        uint256 reputation = reputationManager.getReputation(agentId);
        // Should decay 3 times: 10000 -> 9500 -> 9025 -> 8573
        assertLt(reputation, 9000);
    }

    /*//////////////////////////////////////////////////////////////
                          DECAY FACTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetDecayFactor() public view {
        uint256 factor = reputationManager.getDecayFactor();
        assertEq(factor, 500); // Default 5%
    }

    function test_SetDecayFactor() public {
        vm.expectEmit(false, false, false, true);
        emit DecayFactorUpdated(500, 1000);
        reputationManager.setDecayFactor(1000);

        assertEq(reputationManager.getDecayFactor(), 1000);
    }

    function test_SetDecayFactor_RevertOnInvalid() public {
        vm.expectRevert(abi.encodeWithSelector(ReputationManager.InvalidDecayFactor.selector, 10_001));
        reputationManager.setDecayFactor(10_001);
    }

    function test_SetDecayFactor_RevertOnNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        reputationManager.setDecayFactor(1000);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetAuthorizedRecorder() public {
        address newRecorder = makeAddr("newRecorder");

        vm.expectEmit(true, false, false, true);
        emit RecorderAuthorized(newRecorder, true);
        reputationManager.setAuthorizedRecorder(newRecorder, true);

        assertTrue(reputationManager.authorizedRecorders(newRecorder));
    }

    function test_OwnerCanRecord() public {
        bytes32 queryId = keccak256("query1");

        // Owner should be able to record without explicit authorization
        reputationManager.recordSuccess(agentId, queryId);

        IReputationManager.QueryStats memory stats = reputationManager.getQueryStats(agentId);
        assertEq(stats.totalQueries, 1);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ReputationCalculation(uint8 successes, uint8 failures) public {
        vm.assume(successes > 0 || failures > 0);
        vm.assume(successes <= 100 && failures <= 100);

        vm.startPrank(recorder);
        for (uint256 i = 0; i < successes; i++) {
            reputationManager.recordSuccess(agentId, keccak256(abi.encodePacked("success", i)));
        }
        for (uint256 i = 0; i < failures; i++) {
            reputationManager.recordFailure(agentId, keccak256(abi.encodePacked("failure", i)));
        }
        vm.stopPrank();

        uint256 reputation = reputationManager.getReputation(agentId);
        uint256 expected = (uint256(successes) * 10_000) / (uint256(successes) + uint256(failures));

        assertEq(reputation, expected);
    }

    /// @dev Audit regression L4
    function test_RevertOnZeroAddresses() public {
        vm.expectRevert(ReputationManager.ZeroAddress.selector);
        new ReputationManager(owner, address(0));

        vm.expectRevert(ReputationManager.ZeroAddress.selector);
        reputationManager.setAuthorizedRecorder(address(0), true);
    }
}
