// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IntegrationBase} from "./Base.t.sol";
import {IAgentRegistry} from "../../src/interfaces/IAgentRegistry.sol";
import {IQueryConsumer} from "../../src/interfaces/IQueryConsumer.sol";
import {IReputationManager} from "../../src/interfaces/IReputationManager.sol";
import {IStakingPool} from "../../src/interfaces/IStakingPool.sol";
import {QueryConsumer} from "../../src/QueryConsumer.sol";
import {StakingPool} from "../../src/StakingPool.sol";

/**
 * @title FullFlowTest
 * @author Berke (pzzaworks)
 * @notice Integration tests for complete oracle flows
 * @dev Tests end-to-end scenarios involving all contracts
 */
contract FullFlowTest is IntegrationBase {
    /*//////////////////////////////////////////////////////////////
                        COMPLETE ORACLE FLOW
    //////////////////////////////////////////////////////////////*/

    function test_CompleteOracleFlow() public {
        // 1. Alice registers as an agent
        bytes32 agentId = _registerAgent(alice, ENDPOINT_ALICE);

        // Verify agent registration
        IAgentRegistry.AgentInfo memory agentInfo = registry.getAgent(agentId);
        assertEq(agentInfo.owner, alice);
        assertEq(agentInfo.endpoint, ENDPOINT_ALICE);
        assertTrue(registry.isActiveAgent(agentId));

        // 2. Alice stakes ETH for her agent
        vm.prank(alice);
        staking.stake{value: 1 ether}(agentId);

        // Verify stake
        IStakingPool.StakeInfo memory stakeInfo = staking.getStake(agentId, alice);
        assertEq(stakeInfo.amount, 1 ether);
        assertEq(staking.getTotalStake(agentId), 1 ether);

        // 3. Bob creates a query
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentId;

        vm.prank(requester);
        bytes32 queryId =
            query.createQuery{value: 0.1 ether}("price_feed", abi.encode("ETH/USD"), block.timestamp + 1 hours, agents);

        // Verify query creation
        IQueryConsumer.QueryInfo memory queryInfo = query.getQuery(queryId);
        assertEq(queryInfo.requester, requester);
        assertEq(queryInfo.queryType, "price_feed");
        assertEq(uint256(queryInfo.status), uint256(IQueryConsumer.QueryStatus.Pending));
        assertEq(queryInfo.payment, 0.1 ether);

        // 4. Alice submits a response
        uint256 priceResponse = 2500e18;
        vm.prank(alice);
        query.submitResponse(queryId, agentId, abi.encode(priceResponse));

        // Verify response
        queryInfo = query.getQuery(queryId);
        assertEq(uint256(queryInfo.status), uint256(IQueryConsumer.QueryStatus.InProgress));

        IQueryConsumer.ResponseInfo[] memory responses = query.getResponses(queryId);
        assertEq(responses.length, 1);
        assertEq(responses[0].agentId, agentId);

        // 5. Finalize the query
        bytes32[] memory accepted = _responders(queryId);
        vm.prank(finalizer);
        query.finalizeQuery(queryId, abi.encode(priceResponse), accepted);

        // Verify finalization
        queryInfo = query.getQuery(queryId);
        assertEq(uint256(queryInfo.status), uint256(IQueryConsumer.QueryStatus.Completed));

        bytes memory result = query.getAggregatedResult(queryId);
        assertEq(abi.decode(result, (uint256)), priceResponse);

        // 6. Verify reputation was recorded
        IReputationManager.QueryStats memory stats = reputation.getQueryStats(agentId);
        assertEq(stats.totalQueries, 1);
        assertEq(stats.successfulQueries, 1);
        assertEq(stats.failedQueries, 0);
    }

    /*//////////////////////////////////////////////////////////////
                      MULTI-AGENT CONSENSUS
    //////////////////////////////////////////////////////////////*/

    function test_MultiAgentConsensus() public {
        // Register and stake for 3 agents
        bytes32 agentId1 = _registerAndStake(alice, ENDPOINT_ALICE, 1 ether);
        bytes32 agentId2 = _registerAndStake(bob, ENDPOINT_BOB, 1 ether);
        bytes32 agentId3 = _registerAndStake(charlie, ENDPOINT_CHARLIE, 1 ether);

        // Create query with all 3 agents
        bytes32[] memory agents = new bytes32[](3);
        agents[0] = agentId1;
        agents[1] = agentId2;
        agents[2] = agentId3;

        vm.prank(requester);
        bytes32 queryId =
            query.createQuery{value: 0.3 ether}("price_feed", abi.encode("ETH/USD"), block.timestamp + 1 hours, agents);

        // Each agent submits slightly different prices
        vm.prank(alice);
        query.submitResponse(queryId, agentId1, abi.encode(uint256(2500e18)));

        vm.prank(bob);
        query.submitResponse(queryId, agentId2, abi.encode(uint256(2510e18)));

        vm.prank(charlie);
        query.submitResponse(queryId, agentId3, abi.encode(uint256(2490e18)));

        // Verify all responses recorded
        IQueryConsumer.ResponseInfo[] memory responses = query.getResponses(queryId);
        assertEq(responses.length, 3);

        // Finalize with median value
        uint256 medianPrice = 2500e18;
        bytes32[] memory accepted = _responders(queryId);
        vm.prank(finalizer);
        query.finalizeQuery(queryId, abi.encode(medianPrice), accepted);

        // Verify all agents got reputation boost
        assertEq(reputation.getQueryStats(agentId1).successfulQueries, 1);
        assertEq(reputation.getQueryStats(agentId2).successfulQueries, 1);
        assertEq(reputation.getQueryStats(agentId3).successfulQueries, 1);

        // Verify query completed
        IQueryConsumer.QueryInfo memory queryInfo = query.getQuery(queryId);
        assertEq(uint256(queryInfo.status), uint256(IQueryConsumer.QueryStatus.Completed));
    }

    /*//////////////////////////////////////////////////////////////
                        SLASHING FLOW
    //////////////////////////////////////////////////////////////*/

    function test_SlashingOnMisbehavior() public {
        // Register and stake
        bytes32 agentId = _registerAndStake(alice, ENDPOINT_ALICE, 2 ether);

        // Verify initial stake
        assertEq(staking.getTotalStake(agentId), 2 ether);
        IStakingPool.StakeInfo memory stakeBefore = staking.getStake(agentId, alice);
        assertEq(stakeBefore.amount, 2 ether);

        // Record treasury balance before
        uint256 treasuryBefore = address(treasury).balance;

        // Slash 20% (2000 basis points)
        vm.prank(deployer);
        staking.slash(agentId, 2000, "Misbehavior detected");

        // Verify stake reduced
        IStakingPool.StakeInfo memory stakeAfter = staking.getStake(agentId, alice);
        assertEq(stakeAfter.amount, 1.6 ether); // 2 ETH - 20%
        assertEq(staking.getTotalStake(agentId), 1.6 ether);

        // Verify treasury received slashed funds
        assertEq(address(treasury).balance - treasuryBefore, 0.4 ether);

        // Verify agent status changed to Slashed
        assertEq(uint256(registry.getAgentStatus(agentId)), uint256(IAgentRegistry.AgentStatus.Slashed));
    }

    /*//////////////////////////////////////////////////////////////
                        STAKING & UNSTAKING
    //////////////////////////////////////////////////////////////*/

    function test_StakingUnstakingWithdraw() public {
        // Register agent
        bytes32 agentId = _registerAgent(alice, ENDPOINT_ALICE);

        // Stake
        vm.prank(alice);
        staking.stake{value: 2 ether}(agentId);

        IStakingPool.StakeInfo memory stakeInfo = staking.getStake(agentId, alice);
        assertEq(stakeInfo.amount, 2 ether);

        // Request unstake
        vm.prank(alice);
        staking.unstake(agentId, 1 ether);

        // Verify pending unstake
        assertEq(staking.getStake(agentId, alice).unbondingAmount, 1 ether);
        stakeInfo = staking.getStake(agentId, alice);
        assertEq(stakeInfo.amount, 1 ether);

        // Try to withdraw before timelock - should fail
        vm.prank(alice);
        vm.expectRevert();
        staking.withdraw(agentId);

        // Advance time past unstaking period
        vm.warp(block.timestamp + UNSTAKING_PERIOD + 1);

        // Now withdraw should succeed
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        staking.withdraw(agentId);

        assertEq(alice.balance - balanceBefore, 1 ether);
        assertEq(staking.getStake(agentId, alice).unbondingAmount, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        REWARD DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    function test_RewardDistribution() public {
        // Register and stake with multiple stakers
        bytes32 agentId = _registerAgent(alice, ENDPOINT_ALICE);

        vm.prank(alice);
        staking.stake{value: 3 ether}(agentId);

        vm.prank(bob);
        staking.stake{value: 1 ether}(agentId);

        // Distribute 1 ETH in rewards
        vm.deal(address(this), 1 ether);
        staking.distributeRewards{value: 1 ether}(agentId);

        // Check pending rewards proportional to stake
        // Alice has 75% (3 ETH of 4 ETH total), Bob has 25%
        IStakingPool.StakeInfo memory aliceStake = staking.getStake(agentId, alice);
        IStakingPool.StakeInfo memory bobStake = staking.getStake(agentId, bob);

        assertEq(aliceStake.pendingRewards, 0.75 ether);
        assertEq(bobStake.pendingRewards, 0.25 ether);

        // Claim rewards
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        staking.claimRewards(agentId);
        assertEq(alice.balance - aliceBalanceBefore, 0.75 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        QUERY CANCELLATION
    //////////////////////////////////////////////////////////////*/

    function test_QueryCancellation() public {
        bytes32 agentId = _registerAgent(alice, ENDPOINT_ALICE);

        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentId;

        uint256 balanceBefore = requester.balance;

        vm.prank(requester);
        bytes32 queryId =
            query.createQuery{value: 0.5 ether}("price_feed", abi.encode("ETH/USD"), block.timestamp + 1 hours, agents);

        assertEq(requester.balance, balanceBefore - 0.5 ether);

        // Cancel the query
        vm.prank(requester);
        query.cancelQuery(queryId);

        // Verify refund
        assertEq(requester.balance, balanceBefore);

        // Verify status
        IQueryConsumer.QueryInfo memory queryInfo = query.getQuery(queryId);
        assertEq(uint256(queryInfo.status), uint256(IQueryConsumer.QueryStatus.Failed));
    }

    /*//////////////////////////////////////////////////////////////
                      REPUTATION DECAY TEST
    //////////////////////////////////////////////////////////////*/

    function test_ReputationBuildsWithSuccessfulQueries() public {
        bytes32 agentId = _registerAndStake(alice, ENDPOINT_ALICE, 1 ether);

        // Initial reputation (no queries yet)
        uint256 initialRep = reputation.getReputation(agentId);
        assertEq(initialRep, 5000); // INITIAL_REPUTATION

        // Complete 5 successful queries
        for (uint256 i = 0; i < 5; i++) {
            bytes32 queryId = _createSingleAgentQuery(requester, agentId, 0.1 ether);
            _submitResponse(alice, queryId, agentId, 2500e18);
            _finalizeQuery(queryId, 2500e18);
        }

        // Reputation should be 100% (10000) after 5 successful queries
        IReputationManager.QueryStats memory stats = reputation.getQueryStats(agentId);
        assertEq(stats.totalQueries, 5);
        assertEq(stats.successfulQueries, 5);

        uint256 finalRep = reputation.getReputation(agentId);
        assertEq(finalRep, 10_000); // MAX_REPUTATION (100% success rate)
    }

    /*//////////////////////////////////////////////////////////////
                   AGENT SUSPENSION & REACTIVATION
    //////////////////////////////////////////////////////////////*/

    function test_AgentSuspensionAndReactivation() public {
        bytes32 agentId = _registerAgent(alice, ENDPOINT_ALICE);

        assertTrue(registry.isActiveAgent(agentId));

        // Owner suspends agent
        vm.prank(alice);
        registry.suspendAgent(agentId, "Maintenance");

        assertFalse(registry.isActiveAgent(agentId));
        assertEq(uint256(registry.getAgentStatus(agentId)), uint256(IAgentRegistry.AgentStatus.Suspended));

        // Owner reactivates
        vm.prank(alice);
        registry.reactivateAgent(agentId);

        assertTrue(registry.isActiveAgent(agentId));
        assertEq(uint256(registry.getAgentStatus(agentId)), uint256(IAgentRegistry.AgentStatus.Active));
    }

    /*//////////////////////////////////////////////////////////////
                      EXPIRED QUERY HANDLING
    //////////////////////////////////////////////////////////////*/

    function test_ExpiredQueryWithNoResponses() public {
        bytes32 agentId = _registerAndStake(alice, ENDPOINT_ALICE, 1 ether);

        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentId;

        uint256 requesterBalanceBefore = requester.balance;

        vm.prank(requester);
        bytes32 queryId =
            query.createQuery{value: 0.1 ether}("price_feed", abi.encode("ETH/USD"), block.timestamp + 1 hours, agents);

        // Advance past deadline
        vm.warp(block.timestamp + 2 hours);

        // Fail the expired query (admin action)
        vm.prank(deployer);
        query.failExpiredQuery(queryId);

        // Requester should be refunded
        assertEq(requester.balance, requesterBalanceBefore);

        // Agent should have failed query recorded
        IReputationManager.QueryStats memory stats = reputation.getQueryStats(agentId);
        assertEq(stats.failedQueries, 1);

        // Query should be failed
        IQueryConsumer.QueryInfo memory queryInfo = query.getQuery(queryId);
        assertEq(uint256(queryInfo.status), uint256(IQueryConsumer.QueryStatus.Failed));
    }

    /*//////////////////////////////////////////////////////////////
                       MULTIPLE STAKERS
    //////////////////////////////////////////////////////////////*/

    function test_MultipleStakersOnSameAgent() public {
        bytes32 agentId = _registerAgent(alice, ENDPOINT_ALICE);

        // Alice stakes 2 ETH
        vm.prank(alice);
        staking.stake{value: 2 ether}(agentId);

        // Bob stakes 1 ETH on Alice's agent
        vm.prank(bob);
        staking.stake{value: 1 ether}(agentId);

        // Charlie stakes 3 ETH on Alice's agent
        vm.prank(charlie);
        staking.stake{value: 3 ether}(agentId);

        // Total should be 6 ETH
        assertEq(staking.getTotalStake(agentId), 6 ether);

        // Check individual stakes
        assertEq(staking.getStake(agentId, alice).amount, 2 ether);
        assertEq(staking.getStake(agentId, bob).amount, 1 ether);
        assertEq(staking.getStake(agentId, charlie).amount, 3 ether);

        // Check stakers list
        uint256 stakerCount = staking.getStakerCount(agentId);
        assertEq(stakerCount, 3);
    }

    /*//////////////////////////////////////////////////////////////
                    END-TO-END ECONOMIC FLOW
    //////////////////////////////////////////////////////////////*/

    function test_EndToEndEconomicFlow() public {
        // Setup: Agent registered and staked
        bytes32 agentId = _registerAndStake(alice, ENDPOINT_ALICE, 5 ether);

        uint256 aliceInitialBalance = alice.balance;
        uint256 requesterInitialBalance = requester.balance;

        // Requester creates query
        bytes32 queryId = _createSingleAgentQuery(requester, agentId, 1 ether);
        assertEq(requester.balance, requesterInitialBalance - 1 ether);

        // Agent responds
        _submitResponse(alice, queryId, agentId, 2500e18);

        // Finalize
        _finalizeQuery(queryId, 2500e18);

        // Verify query completed
        IQueryConsumer.QueryInfo memory queryInfo = query.getQuery(queryId);
        assertEq(uint256(queryInfo.status), uint256(IQueryConsumer.QueryStatus.Completed));

        // Reputation updated
        assertEq(reputation.getQueryStats(agentId).successfulQueries, 1);
    }
}

/**
 * @title EdgeCasesTest
 * @author Berke (pzzaworks)
 * @notice Tests for edge cases and error conditions
 */
contract EdgeCasesTest is IntegrationBase {
    function test_CannotQueryInactiveAgent() public {
        bytes32 agentId = _registerAgent(alice, ENDPOINT_ALICE);

        // Suspend the agent
        vm.prank(alice);
        registry.suspendAgent(agentId, "Testing");

        // Try to create query with suspended agent
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentId;

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.AgentNotActive.selector, agentId));
        query.createQuery{value: 0.1 ether}("price_feed", abi.encode("ETH/USD"), block.timestamp + 1 hours, agents);
    }

    function test_CannotStakeOnInactiveAgent() public {
        bytes32 agentId = _registerAgent(alice, ENDPOINT_ALICE);

        // Suspend the agent
        vm.prank(alice);
        registry.suspendAgent(agentId, "Testing");

        // Try to stake on suspended agent
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.AgentNotActive.selector, agentId));
        staking.stake{value: 1 ether}(agentId);
    }

    function test_CannotRespondAfterDeadline() public {
        bytes32 agentId = _registerAndStake(alice, ENDPOINT_ALICE, 1 ether);
        bytes32 queryId = _createSingleAgentQuery(requester, agentId, 0.1 ether);

        // Move past deadline
        vm.warp(block.timestamp + 2 hours);

        // Try to respond
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.QueryExpired.selector, queryId));
        query.submitResponse(queryId, agentId, abi.encode(uint256(2500e18)));
    }

    function test_CannotDoubleRespond() public {
        bytes32 agentId = _registerAndStake(alice, ENDPOINT_ALICE, 1 ether);
        bytes32 queryId = _createSingleAgentQuery(requester, agentId, 0.1 ether);

        // First response
        vm.prank(alice);
        query.submitResponse(queryId, agentId, abi.encode(uint256(2500e18)));

        // Try second response
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.AlreadyResponded.selector, queryId, agentId));
        query.submitResponse(queryId, agentId, abi.encode(uint256(2600e18)));
    }

    function test_OnlyRequesterCanCancel() public {
        bytes32 agentId = _registerAgent(alice, ENDPOINT_ALICE);
        bytes32 queryId = _createSingleAgentQuery(requester, agentId, 0.1 ether);

        // Bob tries to cancel
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.NotQueryRequester.selector, queryId));
        query.cancelQuery(queryId);
    }

    function test_CannotCancelInProgressQuery() public {
        bytes32 agentId = _registerAndStake(alice, ENDPOINT_ALICE, 1 ether);
        bytes32 queryId = _createSingleAgentQuery(requester, agentId, 0.1 ether);

        // Submit response (moves to InProgress)
        _submitResponse(alice, queryId, agentId, 2500e18);

        // Try to cancel
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(IQueryConsumer.QueryNotPending.selector, queryId));
        query.cancelQuery(queryId);
    }

    function test_SlashExceedsMaximum() public {
        bytes32 agentId = _registerAndStake(alice, ENDPOINT_ALICE, 2 ether);

        // Try to slash more than maximum (50%)
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(StakingPool.InvalidSlashPercentage.selector, 6000));
        staking.slash(agentId, 6000, "Excessive slash attempt");
    }
}
