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
        // 100 bps (1%) annualized fee on total assets
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

        // Immediately redeem — no time elapsed, no fee
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
    // No fee when no time has elapsed
    // ---------------------------------------------------------------

    function test_noFeeWithoutTimeElapsed() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // No time elapsed — no fee shares should accrue
        assertEq(wrapper.pendingFeeShares(), 0, "No pending fees without time elapsed");
        assertEq(wrapper.balanceOf(FEE_COLLECTOR), 0, "No fee shares without time elapsed");
    }

    // ---------------------------------------------------------------
    // Fee accrues over time on total assets
    // ---------------------------------------------------------------

    function test_feeAccruesOverTime() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Warp 1 full year — fee should be ~1% of 1000 = ~10 tokens
        vm.warp(block.timestamp + 365 days);

        wrapper.collectFees();
        uint256 feeShares = wrapper.balanceOf(FEE_COLLECTOR);
        assertGt(feeShares, 0, "Fee shares should be minted after time passes");

        // Fee shares should represent ~1% of total assets (annualized).
        // Dilution-based fees yield slightly less than the nominal percentage
        // because minting fee shares dilutes the pool (~0.99% instead of 1%).
        uint256 feeValue = wrapper.convertToAssets(feeShares);
        uint256 expectedFee = depositAmount * 100 / 10000; // 1% of 1000e18 = 10e18
        assertApproxEqAbs(feeValue, expectedFee, 2e17, "Fee value should be ~1% of total assets after 1 year");
    }

    // ---------------------------------------------------------------
    // Fee prorates correctly for partial year
    // ---------------------------------------------------------------

    function test_feeProRatesForPartialYear() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Warp half a year — fee should be ~0.5% of 1000 = ~5 tokens
        vm.warp(block.timestamp + 365 days / 2);

        wrapper.collectFees();
        uint256 feeShares = wrapper.balanceOf(FEE_COLLECTOR);
        // Dilution effect means actual fee value is slightly below nominal
        uint256 feeValue = wrapper.convertToAssets(feeShares);
        uint256 expectedFee = depositAmount * 100 / 10000 / 2; // 0.5% of 1000e18 = 5e18
        assertApproxEqAbs(feeValue, expectedFee, 1e17, "Fee should be ~0.5% after half a year");
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

        // Warp 1 year so fee accrues
        vm.warp(block.timestamp + 365 days);

        wrapper.collectFees();
        uint256 feeShares = wrapper.balanceOf(FEE_COLLECTOR);
        assertGt(feeShares, 0, "Fee collector should receive wrapper shares");

        // Redeem fee shares to verify asset value is ~1% of total assets
        vm.prank(FEE_COLLECTOR);
        uint256 feeAssets = wrapper.redeem(feeShares, FEE_COLLECTOR, FEE_COLLECTOR);

        uint256 expectedFee = depositAmount * 100 / 10000; // 10e18
        assertApproxEqAbs(
            feeAssets,
            expectedFee,
            2e17,
            "Fee collector should receive ~1% of total assets when redeeming after 1 year"
        );
    }

    // ---------------------------------------------------------------
    // Fee collection resets timestamp
    // ---------------------------------------------------------------

    function test_collectFeesResetsTimestamp() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Warp and collect
        vm.warp(block.timestamp + 365 days);
        wrapper.collectFees();

        // After collection, calling collectFees again immediately should mint zero new shares
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
    // No-op collectFees when no time elapsed
    // ---------------------------------------------------------------

    function test_collectFeesNoOpWithoutTimeElapsed() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        uint256 feeSharesBefore = wrapper.balanceOf(FEE_COLLECTOR);
        wrapper.collectFees();
        uint256 feeSharesAfter = wrapper.balanceOf(FEE_COLLECTOR);

        assertEq(feeSharesAfter, feeSharesBefore, "No fee shares minted without time elapsed");
    }

    // ---------------------------------------------------------------
    // Immutable fee collector
    // ---------------------------------------------------------------

    function test_feeCollectorIsImmutable() public view {
        assertEq(wrapper.feeCollector(), FEE_COLLECTOR, "Fee collector must match constructor arg");
    }

    // ---------------------------------------------------------------
    // Fee accrues even without yield in underlying
    // ---------------------------------------------------------------

    function test_feeAccruesWithoutUnderlyingYield() public {
        uint256 depositAmount = 1000e18;

        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Warp 1 year — no yield in underlying, but fee still accrues on total assets
        vm.warp(block.timestamp + 365 days);

        uint256 pending = wrapper.pendingFeeShares();
        assertGt(pending, 0, "Fee should accrue on total assets even without underlying yield");
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
        // 300 bps (3%) annualized fee on total assets
        wrapper = VaultWrapper(
            factory.deploy(address(underlyingVault), 300, FEE_COLLECTOR)
        );
    }

    /// @notice Solo depositor deposits USDC, immediately redeems. No time elapsed, no fee.
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

    /// @notice Fuzz across USDC deposit amounts — immediate redeem, no time elapsed.
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

    /// @notice Deposit USDC, warp time, withdraw. Fee applies on total assets over time.
    function test_usdc_withdrawAfterTimeElapsed() public {
        uint256 depositAmount = 1000e6;

        usdc.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Warp 1 year — 3% annualized fee on 1000 USDC = 30 USDC
        vm.warp(block.timestamp + 365 days);

        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);

        // Depositor gets ~970 USDC (1000 - 30 fee), with dilution effect
        uint256 expectedReturn = depositAmount - (depositAmount * 300 / 10000);
        assertApproxEqAbs(returned, expectedReturn, 1_000_000, "Should get principal minus annualized fee");
    }

    /// @notice Deposit, warp short time, withdraw — fee is prorated.
    function test_usdc_depositWarpWithdrawShortTime() public {
        uint256 depositAmount = 500e6;

        usdc.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, DEPOSITOR);

        // Warp 2 hours — very small fee
        vm.warp(block.timestamp + 2 hours);

        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        // 2 hours of 3% annual on 500 USDC is tiny (~0.003 USDC)
        // Should get back nearly all of the deposit
        assertApproxEqAbs(returned, depositAmount, 10_000, "Short time means negligible fee");
    }
}
