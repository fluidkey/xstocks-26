// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {VaultWrapper} from "../src/VaultWrapper.sol";
import {MockERC20, MockERC4626} from "./mocks/MockERC4626.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

contract VaultWrapperTest is Test {
    VaultWrapperFactory public factory;
    MockERC20 public asset;
    MockERC4626 public underlyingVault;
    VaultWrapper public wrapper;

    address constant FEE_COLLECTOR = address(0xFEE);
    address constant DEPOSITOR = address(0xDEAD);

    function setUp() public {
        factory = new VaultWrapperFactory();
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(
            IERC20(address(asset)), "Test Vault", "vTT"
        );
        // 100 bps (1%) fee on yield
        wrapper = VaultWrapper(
            factory.deploy(address(underlyingVault), 100, FEE_COLLECTOR)
        );
    }

    // ---------------------------------------------------------------
    // Non-Transferable Shares
    // ---------------------------------------------------------------

    function testFuzz_nonTransferableShares(
        address from,
        address to,
        uint256 amount
    ) public {
        vm.assume(from != address(0));
        vm.assume(to != address(0));

        vm.prank(from);
        vm.expectRevert(VaultWrapper.TransfersDisabled.selector);
        wrapper.transfer(to, amount);

        vm.prank(from);
        vm.expectRevert(VaultWrapper.TransfersDisabled.selector);
        wrapper.transferFrom(from, to, amount);

        vm.prank(from);
        vm.expectRevert(VaultWrapper.ApprovalsDisabled.selector);
        wrapper.approve(to, amount);
    }

    // ---------------------------------------------------------------
    // Deposit Mints Correct Shares
    // ---------------------------------------------------------------

    function testFuzz_depositMintsCorrectShares(uint256 assets) public {
        assets = bound(assets, 1e6, 1e24);

        asset.mint(DEPOSITOR, assets);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), assets);

        uint256 expectedShares = wrapper.convertToShares(assets);
        wrapper.deposit(assets, DEPOSITOR);
        vm.stopPrank();

        assertEq(
            wrapper.balanceOf(DEPOSITOR),
            expectedShares,
            "Minted shares must equal convertToShares snapshot before deposit"
        );
    }

    // ---------------------------------------------------------------
    // Deposit-Withdraw Round Trip (18 decimals)
    // ---------------------------------------------------------------

    function testFuzz_depositWithdrawRoundTrip(uint256 assets) public {
        assets = bound(assets, 1e6, 1e24);

        asset.mint(DEPOSITOR, assets);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), assets);

        uint256 shares = wrapper.deposit(assets, DEPOSITOR);

        // Immediately redeem — no yield, no fee
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        assertApproxEqAbs(
            returned,
            assets,
            2,
            "Round-trip must return deposited assets within 2 wei tolerance"
        );
    }

    // ---------------------------------------------------------------
    // Fee only applies to yield, not principal
    // ---------------------------------------------------------------

    function test_noFeeWithoutYield() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // No yield generated — no fee shares should be minted
        assertEq(wrapper.balanceOf(FEE_COLLECTOR), 0, "No fee shares without yield");
    }

    // ---------------------------------------------------------------
    // Fee accrues correctly on yield
    // ---------------------------------------------------------------

    function test_feeAccruesOnYield() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Simulate yield by minting extra assets directly to the underlying vault
        uint256 yieldAmount = 100e18;
        asset.mint(address(underlyingVault), yieldAmount);

        // Collect fees — should mint shares to feeCollector
        wrapper.collectFees();
        uint256 feeShares = wrapper.balanceOf(FEE_COLLECTOR);
        assertGt(feeShares, 0, "Fee shares should be minted on yield");

        // Fee shares should represent ~1% of yield when redeemed
        uint256 feeValue = wrapper.convertToAssets(feeShares);
        uint256 expectedFee = yieldAmount * 100 / 10000;
        assertApproxEqAbs(feeValue, expectedFee, 1e16, "Fee value should be ~1% of yield");
    }

    // ---------------------------------------------------------------
    // Fee collection sends assets to collector
    // ---------------------------------------------------------------

    function test_collectFeesSendsToCollector() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Simulate yield
        uint256 yieldAmount = 100e18;
        asset.mint(address(underlyingVault), yieldAmount);

        wrapper.collectFees();
        uint256 feeShares = wrapper.balanceOf(FEE_COLLECTOR);
        assertGt(feeShares, 0, "Fee collector should receive wrapper shares");

        // Redeem fee shares to verify asset value is ~1% of yield
        vm.prank(FEE_COLLECTOR);
        uint256 feeAssets = wrapper.redeem(feeShares, FEE_COLLECTOR, FEE_COLLECTOR);

        assertApproxEqAbs(
            feeAssets,
            1e18,
            1e16,
            "Fee collector should receive ~1% of yield when redeeming"
        );
    }

    // ---------------------------------------------------------------
    // Fee collection resets baseline
    // ---------------------------------------------------------------

    function test_collectFeesResetsBaseline() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Simulate yield and collect
        asset.mint(address(underlyingVault), 100e18);
        wrapper.collectFees();

        // After collection, calling collectFees again should mint zero new shares
        uint256 feeSharesBefore = wrapper.balanceOf(FEE_COLLECTOR);
        wrapper.collectFees();
        uint256 feeSharesAfter = wrapper.balanceOf(FEE_COLLECTOR);
        assertEq(
            feeSharesAfter,
            feeSharesBefore,
            "After fee collection, no pending fee should remain"
        );
    }

    // ---------------------------------------------------------------
    // No-op collectFees when no yield
    // ---------------------------------------------------------------

    function test_collectFeesNoOpWithoutYield() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        uint256 feeSharesBefore = wrapper.balanceOf(FEE_COLLECTOR);
        wrapper.collectFees();
        uint256 feeSharesAfter = wrapper.balanceOf(FEE_COLLECTOR);

        assertEq(feeSharesAfter, feeSharesBefore, "No fee shares minted without yield");
    }

    // ---------------------------------------------------------------
    // Immutable fee collector
    // ---------------------------------------------------------------

    function test_feeCollectorIsImmutable() public view {
        assertEq(wrapper.feeCollector(), FEE_COLLECTOR, "Fee collector must match constructor arg");
    }
}


// ===============================================================
// USDC (6-decimal) round trip tests
// ===============================================================

contract VaultWrapperUSDCRoundTripTest is Test {
    VaultWrapperFactory public factory;
    MockERC20 public usdc;
    MockERC4626 public underlyingVault;
    VaultWrapper public wrapper;

    address constant FEE_COLLECTOR = address(0xFEE);
    address constant DEPOSITOR = address(0xDEAD);

    function setUp() public {
        factory = new VaultWrapperFactory();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        underlyingVault = new MockERC4626(
            IERC20(address(usdc)), "USDC Vault", "vUSDC"
        );
        // 300 bps (3%) fee on yield
        wrapper = VaultWrapper(
            factory.deploy(address(underlyingVault), 300, FEE_COLLECTOR)
        );
    }

    /// @notice Solo depositor deposits USDC, immediately redeems. No yield, no fee.
    function test_usdc_depositRedeemImmediately() public {
        uint256 depositAmount = 1000e6;

        usdc.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), depositAmount);

        uint256 shares = wrapper.deposit(depositAmount, DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        assertApproxEqAbs(returned, depositAmount, 2, "USDC round-trip within 2 wei");
    }

    /// @notice Solo depositor deposits USDC, immediately withdraws exact assets.
    function test_usdc_depositWithdrawImmediately() public {
        uint256 depositAmount = 1000e6;

        usdc.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), depositAmount);

        wrapper.deposit(depositAmount, DEPOSITOR);

        uint256 maxAssets = wrapper.convertToAssets(wrapper.balanceOf(DEPOSITOR));
        wrapper.withdraw(maxAssets, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(DEPOSITOR), 0, "Should have zero shares after full withdrawal");
    }

    /// @notice Fuzz across USDC deposit amounts — immediate redeem, no yield.
    function testFuzz_usdc_depositRedeemRoundTrip(uint256 assets) public {
        assets = bound(assets, 1e6, 10_000_000e6);

        usdc.mint(DEPOSITOR, assets);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), assets);

        uint256 shares = wrapper.deposit(assets, DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        assertApproxEqAbs(returned, assets, 2, "USDC fuzz round-trip within 2 wei");
    }

    /// @notice Fuzz the withdraw path with 6-decimal tokens.
    function testFuzz_usdc_depositWithdrawRoundTrip(uint256 assets) public {
        assets = bound(assets, 1e6, 10_000_000e6);

        usdc.mint(DEPOSITOR, assets);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), assets);

        wrapper.deposit(assets, DEPOSITOR);

        uint256 maxAssets = wrapper.convertToAssets(wrapper.balanceOf(DEPOSITOR));
        wrapper.withdraw(maxAssets, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(DEPOSITOR), assets, 2, "USDC fuzz withdraw within 2 wei");
    }

    /// @notice Deposit USDC, simulate yield, withdraw. Fee should only apply to yield.
    function test_usdc_withdrawAfterYield() public {
        uint256 depositAmount = 1000e6;

        usdc.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Simulate 10 USDC yield in the underlying vault
        usdc.mint(address(underlyingVault), 10e6);

        // Redeem all shares — fee dilution is reflected in real-time via
        // totalSupply() override, so depositor gets principal + yield minus fee.
        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);

        // Fee = 3% of 10 USDC = 0.3 USDC. Depositor gets ~1009.7 USDC
        assertApproxEqAbs(returned, 1009_700_000, 10_000, "Should get principal + yield - fee");
    }

    /// @notice Deposit, time passes (no actual yield in mock), withdraw works fine.
    function test_usdc_depositWarpWithdrawNoYield() public {
        uint256 depositAmount = 500e6;

        usdc.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, DEPOSITOR);

        // Warp 2 hours — no yield in mock vault, so no fee
        vm.warp(block.timestamp + 2 hours);

        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        // No yield means no fee — should get back full deposit
        assertApproxEqAbs(returned, depositAmount, 2, "No yield means no fee deduction");
    }
}
