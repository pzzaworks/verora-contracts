// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {IERC8004} from "../src/interfaces/IERC8004.sol";

contract AgentRegistryTest is Test {
    AgentRegistry public registry;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public slasher = makeAddr("slasher");

    string public constant ENDPOINT = "https://agent.verora.io";
    string[] public capabilities;
    bytes public constant ATTESTATION = hex"1234567890";

    event AgentRegistered(bytes32 indexed agentId, address indexed owner, string endpoint);
    event AgentUpdated(bytes32 indexed agentId, string endpoint);
    event AgentSuspended(bytes32 indexed agentId, string reason);
    event SlasherAuthorized(address indexed slasher, bool authorized);

    function setUp() public {
        registry = new AgentRegistry(owner);

        capabilities.push("price_feed");
        capabilities.push("data_aggregation");
    }

    /*//////////////////////////////////////////////////////////////
                          REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RegisterAgent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        assertNotEq(agentId, bytes32(0));

        IERC8004.AgentInfo memory info = registry.getAgent(agentId);
        assertEq(info.agentId, agentId);
        assertEq(info.owner, alice);
        assertEq(info.endpoint, ENDPOINT);
        assertEq(info.capabilities.length, 2);
        assertEq(info.capabilities[0], "price_feed");
        assertEq(info.attestation, ATTESTATION);
        assertEq(info.registeredAt, block.timestamp);

        assertTrue(registry.isActiveAgent(agentId));
        assertEq(uint256(registry.getAgentStatus(agentId)), uint256(IAgentRegistry.AgentStatus.Active));
    }

    function test_RegisterAgent_EmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(false, true, false, true);
        emit AgentRegistered(bytes32(0), alice, ENDPOINT);
        registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");
    }

    function test_RegisterAgent_IncrementsCount() public {
        assertEq(registry.getAgentCount(), 0);

        vm.prank(alice);
        registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");
        assertEq(registry.getAgentCount(), 1);

        vm.prank(bob);
        registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");
        assertEq(registry.getAgentCount(), 2);
    }

    function test_RegisterAgent_TracksOwnerAgents() public {
        vm.startPrank(alice);
        bytes32 agentId1 = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");
        bytes32 agentId2 = registry.registerAgent("https://agent2.verora.io", capabilities, ATTESTATION, "");
        vm.stopPrank();

        bytes32[] memory aliceAgents = registry.getAgentsByOwner(alice);
        assertEq(aliceAgents.length, 2);
        assertEq(aliceAgents[0], agentId1);
        assertEq(aliceAgents[1], agentId2);
    }

    function test_RegisterAgent_RevertOnEmptyEndpoint() public {
        vm.prank(alice);
        vm.expectRevert(AgentRegistry.InvalidEndpoint.selector);
        registry.registerAgent("", capabilities, ATTESTATION, "");
    }

    /*//////////////////////////////////////////////////////////////
                            UPDATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateAgent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        string memory newEndpoint = "https://new-agent.verora.io";
        string[] memory newCapabilities = new string[](1);
        newCapabilities[0] = "oracle";
        bytes memory newAttestation = hex"abcdef";

        vm.prank(alice);
        registry.updateAgent(agentId, newEndpoint, newCapabilities, newAttestation);

        IERC8004.AgentInfo memory info = registry.getAgent(agentId);
        assertEq(info.endpoint, newEndpoint);
        assertEq(info.capabilities.length, 1);
        assertEq(info.capabilities[0], "oracle");
        assertEq(info.attestation, newAttestation);
    }

    function test_UpdateAgent_EmitsEvent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        string memory newEndpoint = "https://new-agent.verora.io";

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit AgentUpdated(agentId, newEndpoint);
        registry.updateAgent(agentId, newEndpoint, capabilities, ATTESTATION);
    }

    function test_UpdateAgent_RevertOnNotOwner() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.NotAgentOwner.selector, agentId, bob));
        registry.updateAgent(agentId, ENDPOINT, capabilities, ATTESTATION);
    }

    function test_UpdateAgent_RevertOnNotActive() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        vm.prank(alice);
        registry.suspendAgent(agentId, "Testing");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentNotActive.selector, agentId));
        registry.updateAgent(agentId, ENDPOINT, capabilities, ATTESTATION);
    }

    /*//////////////////////////////////////////////////////////////
                          SUSPENSION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SuspendAgent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        vm.prank(alice);
        registry.suspendAgent(agentId, "Maintenance");

        assertFalse(registry.isActiveAgent(agentId));
        assertEq(uint256(registry.getAgentStatus(agentId)), uint256(IAgentRegistry.AgentStatus.Suspended));
    }

    function test_SuspendAgent_EmitsEvent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit AgentSuspended(agentId, "Maintenance");
        registry.suspendAgent(agentId, "Maintenance");
    }

    function test_ReactivateAgent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        vm.prank(alice);
        registry.suspendAgent(agentId, "Maintenance");

        vm.prank(alice);
        registry.reactivateAgent(agentId);

        assertTrue(registry.isActiveAgent(agentId));
        assertEq(uint256(registry.getAgentStatus(agentId)), uint256(IAgentRegistry.AgentStatus.Active));
    }

    function test_ReactivateAgent_RevertOnSlashed() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        registry.setAuthorizedSlasher(slasher, true);

        vm.prank(slasher);
        registry.slashAgent(agentId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentIsSlashed.selector, agentId));
        registry.reactivateAgent(agentId);
    }

    /*//////////////////////////////////////////////////////////////
                           SLASHING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SlashAgent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        registry.setAuthorizedSlasher(slasher, true);

        vm.prank(slasher);
        registry.slashAgent(agentId);

        assertFalse(registry.isActiveAgent(agentId));
        assertEq(uint256(registry.getAgentStatus(agentId)), uint256(IAgentRegistry.AgentStatus.Slashed));
    }

    function test_SlashAgent_RevertOnUnauthorized() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.NotAuthorizedSlasher.selector, bob));
        registry.slashAgent(agentId);
    }

    function test_SlashAgent_OwnerCanSlash() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        // Owner can slash without explicit authorization
        registry.slashAgent(agentId);

        assertEq(uint256(registry.getAgentStatus(agentId)), uint256(IAgentRegistry.AgentStatus.Slashed));
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetAuthorizedSlasher() public {
        assertFalse(registry.authorizedSlashers(slasher));

        vm.expectEmit(true, false, false, true);
        emit SlasherAuthorized(slasher, true);
        registry.setAuthorizedSlasher(slasher, true);

        assertTrue(registry.authorizedSlashers(slasher));
    }

    function test_AdminSuspendAgent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        registry.adminSuspendAgent(agentId, "Policy violation");

        assertFalse(registry.isActiveAgent(agentId));
    }

    function test_AdminReactivateAgent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        registry.setAuthorizedSlasher(slasher, true);
        vm.prank(slasher);
        registry.slashAgent(agentId);

        // Admin can reactivate even slashed agents
        registry.adminReactivateAgent(agentId);

        assertTrue(registry.isActiveAgent(agentId));
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetAgent_RevertOnNotFound() public {
        bytes32 fakeId = keccak256("fake");

        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentNotFound.selector, fakeId));
        registry.getAgent(fakeId);
    }

    function test_IsActiveAgent_ReturnsFalseForNonExistent() public {
        bytes32 fakeId = keccak256("fake");
        assertFalse(registry.isActiveAgent(fakeId));
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_RegisterAgent(string memory endpoint, bytes memory attestation) public {
        vm.assume(bytes(endpoint).length > 0);

        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(endpoint, capabilities, attestation, "");

        IERC8004.AgentInfo memory info = registry.getAgent(agentId);
        assertEq(info.endpoint, endpoint);
        assertEq(info.attestation, attestation);
    }

    /*//////////////////////////////////////////////////////////////
                         HARDENING REGRESSIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Audit regression: an owner could lift an admin suspension by calling reactivateAgent
    function test_AdminSuspension_CannotBeLiftedByOwner() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        registry.adminSuspendAgent(agentId, "policy");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.AgentIsAdminSuspended.selector, agentId));
        registry.reactivateAgent(agentId);

        registry.adminReactivateAgent(agentId);
        assertTrue(registry.isActiveAgent(agentId));
        assertFalse(registry.adminSuspended(agentId));
    }

    function test_SlashAgent_IsIdempotent() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");
        registry.setAuthorizedSlasher(slasher, true);

        vm.startPrank(slasher);
        registry.slashAgent(agentId);
        registry.slashAgent(agentId);
        vm.stopPrank();

        assertEq(uint256(registry.getAgentStatus(agentId)), uint256(IAgentRegistry.AgentStatus.Slashed));
    }

    function test_RegisterAgent_EnforcesInputBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(AgentRegistry.InvalidEndpoint.selector);
        registry.registerAgent(string(new bytes(513)), capabilities, ATTESTATION, "");

        string[] memory tooMany = new string[](33);
        for (uint256 i = 0; i < tooMany.length; i++) {
            tooMany[i] = "cap";
        }
        vm.expectRevert(AgentRegistry.InvalidCapabilities.selector);
        registry.registerAgent(ENDPOINT, tooMany, ATTESTATION, "");

        string[] memory empty = new string[](1);
        vm.expectRevert(AgentRegistry.InvalidCapabilities.selector);
        registry.registerAgent(ENDPOINT, empty, ATTESTATION, "");

        vm.expectRevert(AgentRegistry.InvalidAttestation.selector);
        registry.registerAgent(ENDPOINT, capabilities, new bytes(4097), "");

        vm.expectRevert(AgentRegistry.InvalidMetadataURI.selector);
        registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, string(new bytes(513)));
        vm.stopPrank();
    }

    function test_GetAgentIds_Paginates() public {
        bytes32[] memory ids = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            ids[i] = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");
        }

        bytes32[] memory page = registry.getAgentIds(1, 5);
        assertEq(page.length, 2);
        assertEq(page[0], ids[1]);
        assertEq(page[1], ids[2]);
        assertEq(registry.getAgentIds(3, 5).length, 0);
        assertTrue(registry.agentExists(ids[0]));
        assertFalse(registry.agentExists(keccak256("none")));
    }

    function test_RegisterAgent_RevertsWhenPaused() public {
        registry.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");
    }

    /// @dev Audit regression L4
    function test_SetAuthorizedSlasher_RevertOnZeroAddress() public {
        vm.expectRevert(AgentRegistry.ZeroAddress.selector);
        registry.setAuthorizedSlasher(address(0), true);
    }

    function test_GetAgentAtIndex_RevertsWithCustomError() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        assertEq(registry.getAgentAtIndex(0), agentId);
        assertEq(registry.getAgentCount(), 1);
        vm.expectRevert(abi.encodeWithSelector(AgentRegistry.IndexOutOfBounds.selector, 1, 1));
        registry.getAgentAtIndex(1);
    }

    function test_GetAgentIds_HandlesUnboundedLimit() public {
        vm.prank(alice);
        bytes32 agentId = registry.registerAgent(ENDPOINT, capabilities, ATTESTATION, "");

        bytes32[] memory ids = registry.getAgentIds(0, type(uint256).max);
        assertEq(ids.length, 1);
        assertEq(ids[0], agentId);
    }
}
