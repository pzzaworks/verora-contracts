// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {ERC20Mock, FeeOnTransferERC20Mock} from "./mocks/ERC20Mock.sol";

contract TreasuryTest is Test {
    Treasury public treasury;
    ERC20Mock public usdc;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public distributor = makeAddr("distributor");
    address public recipient = makeAddr("recipient");

    event Deposited(address indexed token, uint256 amount, address indexed source);
    event Distributed(address indexed token, address indexed recipient, uint256 amount);
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed recipient);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event DistributorAuthorized(address indexed distributor, bool authorized);

    function setUp() public {
        treasury = new Treasury(owner);
        usdc = new ERC20Mock("USD Coin", "USDC", 6);

        treasury.setAuthorizedDistributor(distributor, true);

        vm.deal(alice, 100 ether);
        usdc.mint(alice, 10_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                          ETH DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deposit() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}();

        assertEq(treasury.getBalance(address(0)), 1 ether);
    }

    function test_Deposit_EmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, true, true);
        emit Deposited(address(0), 1 ether, alice);
        treasury.deposit{value: 1 ether}();
    }

    function test_Deposit_ViaReceive() public {
        vm.prank(alice);
        (bool success,) = address(treasury).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(treasury.getBalance(address(0)), 1 ether);
    }

    function test_Deposit_RevertOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.deposit{value: 0}();
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositERC20() public {
        treasury.addSupportedToken(address(usdc));

        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.depositERC20(address(usdc), 100e6);
        vm.stopPrank();

        assertEq(treasury.getBalance(address(usdc)), 100e6);
    }

    function test_DepositERC20_EmitsEvent() public {
        treasury.addSupportedToken(address(usdc));

        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        vm.expectEmit(true, false, true, true);
        emit Deposited(address(usdc), 100e6, alice);
        treasury.depositERC20(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_DepositERC20_RevertOnUnsupportedToken() public {
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.TokenNotSupported.selector, address(usdc)));
        treasury.depositERC20(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_DepositERC20_RevertOnZeroAmount() public {
        treasury.addSupportedToken(address(usdc));

        vm.prank(alice);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.depositERC20(address(usdc), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         DISTRIBUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Distribute_ETH() public {
        vm.prank(alice);
        treasury.deposit{value: 10 ether}();

        uint256 balanceBefore = recipient.balance;

        vm.prank(distributor);
        treasury.distribute(address(0), recipient, 5 ether);

        assertEq(recipient.balance, balanceBefore + 5 ether);
        assertEq(treasury.getBalance(address(0)), 5 ether);
    }

    function test_Distribute_EmitsEvent() public {
        vm.prank(alice);
        treasury.deposit{value: 10 ether}();

        vm.prank(distributor);
        vm.expectEmit(true, true, false, true);
        emit Distributed(address(0), recipient, 5 ether);
        treasury.distribute(address(0), recipient, 5 ether);
    }

    function test_Distribute_ERC20() public {
        treasury.addSupportedToken(address(usdc));

        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.depositERC20(address(usdc), 100e6);
        vm.stopPrank();

        vm.prank(distributor);
        treasury.distribute(address(usdc), recipient, 50e6);

        assertEq(usdc.balanceOf(recipient), 50e6);
    }

    function test_Distribute_RevertOnInsufficientBalance() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}();

        vm.prank(distributor);
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientBalance.selector, 2 ether, 1 ether));
        treasury.distribute(address(0), recipient, 2 ether);
    }

    function test_Distribute_RevertOnUnauthorized() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Treasury.NotAuthorizedDistributor.selector, alice));
        treasury.distribute(address(0), recipient, 0.5 ether);
    }

    function test_Distribute_RevertOnZeroAddress() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}();

        vm.prank(distributor);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.distribute(address(0), address(0), 0.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                     EMERGENCY WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EmergencyWithdraw_ETH() public {
        vm.prank(alice);
        treasury.deposit{value: 10 ether}();

        uint256 balanceBefore = recipient.balance;

        treasury.emergencyWithdraw(address(0), 10 ether, recipient);

        assertEq(recipient.balance, balanceBefore + 10 ether);
    }

    function test_EmergencyWithdraw_EmitsEvent() public {
        vm.prank(alice);
        treasury.deposit{value: 10 ether}();

        vm.expectEmit(true, false, true, true);
        emit EmergencyWithdrawal(address(0), 10 ether, recipient);
        treasury.emergencyWithdraw(address(0), 10 ether, recipient);
    }

    function test_EmergencyWithdraw_ERC20() public {
        treasury.addSupportedToken(address(usdc));

        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.depositERC20(address(usdc), 100e6);
        vm.stopPrank();

        treasury.emergencyWithdraw(address(usdc), 100e6, recipient);

        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function test_EmergencyWithdraw_CapsAtBalance() public {
        vm.prank(alice);
        treasury.deposit{value: 5 ether}();

        uint256 balanceBefore = recipient.balance;

        // Try to withdraw more than balance
        treasury.emergencyWithdraw(address(0), 100 ether, recipient);

        // Should only withdraw actual balance
        assertEq(recipient.balance, balanceBefore + 5 ether);
    }

    function test_EmergencyWithdraw_RevertOnNotOwner() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}();

        vm.prank(alice);
        vm.expectRevert();
        treasury.emergencyWithdraw(address(0), 1 ether, alice);
    }

    /*//////////////////////////////////////////////////////////////
                       TOKEN SUPPORT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddSupportedToken() public {
        vm.expectEmit(true, false, false, false);
        emit TokenAdded(address(usdc));
        treasury.addSupportedToken(address(usdc));

        assertTrue(treasury.isTokenSupported(address(usdc)));
    }

    function test_AddSupportedToken_RevertOnZeroAddress() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.addSupportedToken(address(0));
    }

    function test_AddSupportedToken_RevertOnAlreadySupported() public {
        treasury.addSupportedToken(address(usdc));

        vm.expectRevert(abi.encodeWithSelector(Treasury.TokenAlreadySupported.selector, address(usdc)));
        treasury.addSupportedToken(address(usdc));
    }

    function test_RemoveSupportedToken() public {
        treasury.addSupportedToken(address(usdc));

        vm.expectEmit(true, false, false, false);
        emit TokenRemoved(address(usdc));
        treasury.removeSupportedToken(address(usdc));

        assertFalse(treasury.isTokenSupported(address(usdc)));
    }

    function test_RemoveSupportedToken_RevertOnETH() public {
        vm.expectRevert(abi.encodeWithSelector(Treasury.TokenNotSupported.selector, address(0)));
        treasury.removeSupportedToken(address(0));
    }

    function test_GetSupportedTokens() public {
        treasury.addSupportedToken(address(usdc));

        ERC20Mock dai = new ERC20Mock("Dai Stablecoin", "DAI", 18);
        treasury.addSupportedToken(address(dai));

        address[] memory tokens = treasury.getSupportedTokens();
        assertEq(tokens.length, 3); // ETH + USDC + DAI
        assertEq(tokens[0], address(0));
        assertEq(tokens[1], address(usdc));
        assertEq(tokens[2], address(dai));
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetAuthorizedDistributor() public {
        address newDistributor = makeAddr("newDistributor");

        vm.expectEmit(true, false, false, true);
        emit DistributorAuthorized(newDistributor, true);
        treasury.setAuthorizedDistributor(newDistributor, true);

        assertTrue(treasury.authorizedDistributors(newDistributor));
    }

    function test_OwnerCanDistribute() public {
        vm.prank(alice);
        treasury.deposit{value: 1 ether}();

        // Owner should be able to distribute without explicit authorization
        treasury.distribute(address(0), recipient, 0.5 ether);

        assertEq(recipient.balance, 0.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Deposit(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.deal(alice, amount);

        vm.prank(alice);
        treasury.deposit{value: amount}();

        assertEq(treasury.getBalance(address(0)), amount);
    }

    function testFuzz_Distribute(uint256 depositAmount, uint256 distributeAmount) public {
        depositAmount = bound(depositAmount, 1, 100 ether);
        distributeAmount = bound(distributeAmount, 1, depositAmount);
        vm.deal(alice, depositAmount);

        vm.prank(alice);
        treasury.deposit{value: depositAmount}();

        vm.prank(distributor);
        treasury.distribute(address(0), recipient, distributeAmount);

        assertEq(recipient.balance, distributeAmount);
        assertEq(treasury.getBalance(address(0)), depositAmount - distributeAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           REGRESSION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Audit regression L5: fee-on-transfer deposits inflated the tracked balance
    function test_DepositERC20_RecordsReceivedAmount() public {
        FeeOnTransferERC20Mock feeToken = new FeeOnTransferERC20Mock();
        treasury.addSupportedToken(address(feeToken));
        feeToken.mint(alice, 100 ether);

        vm.startPrank(alice);
        feeToken.approve(address(treasury), 100 ether);
        vm.expectEmit(true, true, false, true);
        emit Deposited(address(feeToken), 99 ether, alice);
        treasury.depositERC20(address(feeToken), 100 ether);
        vm.stopPrank();

        assertEq(treasury.getTrackedBalance(address(feeToken)), 99 ether);
        assertEq(feeToken.balanceOf(address(treasury)), 99 ether);
    }

    /// @dev Audit regression L5: distribution of unsupported tokens bypassed the allow-list
    function test_Distribute_RevertOnUnsupportedToken() public {
        treasury.addSupportedToken(address(usdc));
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.depositERC20(address(usdc), 100e6);
        vm.stopPrank();
        treasury.removeSupportedToken(address(usdc));

        vm.prank(distributor);
        vm.expectRevert(abi.encodeWithSelector(Treasury.TokenNotSupported.selector, address(usdc)));
        treasury.distribute(address(usdc), recipient, 50e6);

        // The owner can still recover the balance through the emergency path
        treasury.emergencyWithdraw(address(usdc), 100e6, recipient);
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    /// @dev Audit regression L4
    function test_SetAuthorizedDistributor_RevertOnZeroAddress() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.setAuthorizedDistributor(address(0), true);
    }
}
