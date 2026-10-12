// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IntegrationBase} from "../integration/Base.t.sol";
import {StakingPool} from "../../src/StakingPool.sol";
import {QueryConsumer} from "../../src/QueryConsumer.sol";
import {IStakingPool} from "../../src/interfaces/IStakingPool.sol";
import {IQueryConsumer} from "../../src/interfaces/IQueryConsumer.sol";

/**
 * @dev Drives random staking and query activity against one agent. Every action is bounded so the
 *      fuzzer explores valid paths instead of reverting.
 */
contract SolvencyHandler is Test {
    StakingPool internal staking;
    QueryConsumer internal query;
    bytes32 internal agentId;
    address internal agentOwner;
    address internal slasher;

    address[] public stakers;
    bytes32[] public openQueries;

    constructor(StakingPool staking_, QueryConsumer query_, bytes32 agentId_, address agentOwner_, address slasher_) {
        staking = staking_;
        query = query_;
        agentId = agentId_;
        agentOwner = agentOwner_;
        slasher = slasher_;
        for (uint256 i = 0; i < 3; i++) {
            address staker = makeAddr(string.concat("staker", vm.toString(i)));
            vm.deal(staker, 1000 ether);
            stakers.push(staker);
        }
    }

    function stakerCount() external view returns (uint256) {
        return stakers.length;
    }

    function openQueryCount() external view returns (uint256) {
        return openQueries.length;
    }

    function stake(uint256 seed, uint256 amount) external {
        address staker = stakers[seed % stakers.length];
        amount = bound(amount, staking.getMinimumStake(), 10 ether);
        vm.prank(staker);
        try staking.stake{value: amount}(agentId) {} catch {}
    }

    function unstake(uint256 seed, uint256 amount) external {
        address staker = stakers[seed % stakers.length];
        uint256 available = staking.getStake(agentId, staker).amount;
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(staker);
        try staking.unstake(agentId, amount) {} catch {}
    }

    function withdraw(uint256 seed) external {
        address staker = stakers[seed % stakers.length];
        vm.prank(staker);
        try staking.withdraw(agentId) {} catch {}
    }

    function claim(uint256 seed) external {
        address staker = stakers[seed % stakers.length];
        vm.prank(staker);
        try staking.claimRewards(agentId) {} catch {}
    }

    function slash(uint256 bps) external {
        bps = bound(bps, 1, 5000);
        vm.prank(slasher);
        staking.slash(agentId, bps, "fuzz");
    }

    function distribute(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(this), amount);
        staking.distributeRewards{value: amount}(agentId);
    }

    function createQuery(uint256 amount) external {
        amount = bound(amount, 0.001 ether, 5 ether);
        bytes32[] memory agents = new bytes32[](1);
        agents[0] = agentId;
        vm.deal(address(this), amount);
        try query.createQuery{value: amount}("plaintext", "q", block.timestamp + 1 hours, agents) returns (bytes32 id) {
            openQueries.push(id);
        } catch {}
    }

    function respondAndFinalize(uint256 seed) external {
        if (openQueries.length == 0) return;
        uint256 index = seed % openQueries.length;
        bytes32 queryId = openQueries[index];
        vm.prank(agentOwner);
        try query.submitResponse(queryId, agentId, "r") {} catch {}
        bytes32[] memory accepted = new bytes32[](1);
        accepted[0] = agentId;
        vm.prank(slasher);
        try query.finalizeQuery(queryId, "r", accepted) {} catch {}
        _removeIfClosed(index);
    }

    function expire(uint256 seed) external {
        if (openQueries.length == 0) return;
        uint256 index = seed % openQueries.length;
        // Past the deadline and the finalizer grace period, so queries with responses can close too
        vm.warp(block.timestamp + 3 hours);
        try query.failExpiredQuery(openQueries[index]) {} catch {}
        _removeIfClosed(index);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 8 days));
    }

    function _removeIfClosed(uint256 index) internal {
        IQueryConsumer.QueryStatus status = query.getQuery(openQueries[index]).status;
        if (status == IQueryConsumer.QueryStatus.Completed || status == IQueryConsumer.QueryStatus.Failed) {
            openQueries[index] = openQueries[openQueries.length - 1];
            openQueries.pop();
        }
    }

    receive() external payable {}
}

contract SolvencyInvariantTest is IntegrationBase {
    SolvencyHandler internal handler;
    bytes32 internal agentId;

    function setUp() public override {
        super.setUp();
        agentId = _registerAgent(alice, ENDPOINT_ALICE);

        // The deployer is the owner, so it can both slash and finalize
        handler = new SolvencyHandler(staking, query, agentId, alice, deployer);
        targetContract(address(handler));
    }

    /// @notice The staking pool always holds enough ETH for every staker position and pending reward
    function invariant_StakingPoolIsSolvent() public view {
        uint256 liabilities;
        for (uint256 i = 0; i < handler.stakerCount(); i++) {
            IStakingPool.StakeInfo memory info = staking.getStake(agentId, handler.stakers(i));
            liabilities += info.amount + info.unbondingAmount + info.pendingRewards;
        }
        assertGe(address(staking).balance, liabilities);
    }

    /// @notice The query escrow always covers every open query plus credited refunds
    function invariant_QueryEscrowIsSolvent() public view {
        uint256 escrow;
        for (uint256 i = 0; i < handler.openQueryCount(); i++) {
            escrow += query.getQuery(handler.openQueries(i)).payment;
        }
        assertGe(address(query).balance, escrow);
    }

    /// @notice The router only ever holds agent-owner fees plus failed treasury pushes
    function invariant_RouterHoldsOnlyOwedFees() public view {
        assertEq(address(payment).balance, payment.getPendingFees(alice) + payment.pendingTreasuryFees());
    }
}
