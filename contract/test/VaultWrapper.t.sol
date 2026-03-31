// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {VaultWrapper} from "../src/VaultWrapper.sol";
import {MockERC20, MockERC4626} from "./mocks/MockERC4626.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

/**
 * Test harness extending VaultWrapper to expose internal state setters.
 * Deployed directly (not via factory) for property-based fuzz tests.
 */
contract VaultWrapperHarness is VaultWrapper {
    constructor(
        address _underlying,
        uint256 _feePercentage
    ) VaultWrapper(_underlying, _feePercentage) {}

    function exposed_setFeeCollectorState(
        address fc,
        uint256 aum,
        uint256 timestamp,
        uint256 settled
    ) external {
        feeCollectorStates[fc] = FeeCollectorState({
            totalAUM: aum,
            lastAccrualTimestamp: timestamp,
            settledVirtualShares: settled
        });
        if (!_isFeeCollectorActive[fc]) {
            _isFeeCollectorActive[fc] = true;
            _activeFeeCollectors.push(fc);
        }
    }

    function exposed_mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function exposed_setTotalSettledVirtualShares(uint256 val) external {
        totalSettledVirtualShares = val;
    }
}

contract VaultWrapperTest is Test {
    VaultWrapperFactory public factory;
    MockERC20 public asset;
    MockERC4626 public underlyingVault;
    VaultWrapper public wrapper;

    function setUp() public {
        factory = new VaultWrapperFactory();
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(
            IERC20(address(asset)), "Test Vault", "vTT"
        );
        wrapper = VaultWrapper(
            factory.deploy(address(underlyingVault), 100)
        );
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 6: Non-Transferable Shares
    // **Validates: Requirements 3.2, 3.3, 3.4**
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
}


// ---------------------------------------------------------------
// Feature: safe-4626-vault-module, Property 7: Virtual Fee Shares Formula
// **Validates: Requirements 4.1**
// ---------------------------------------------------------------

contract VaultWrapperVirtualFeeSharesTest is Test {
    MockERC20 public asset;
    MockERC4626 public underlyingVault;
    VaultWrapperHarness public harness;

    address constant FEE_COLLECTOR = address(0xFEE);

    function setUp() public {
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(
            IERC20(address(asset)), "Test Vault", "vTT"
        );
        // Deploy harness directly with 100 bps (1%) fee — feePercentage
        // is overridden per-test via a fresh harness when needed
    }

    function testFuzz_virtualFeeSharesFormula(
        uint256 aum,
        uint256 feePct,
        uint256 elapsed
    ) public {
        // Bound inputs to meaningful ranges
        aum = bound(aum, 1e18, 1e30);
        feePct = bound(feePct, 1, 5000);
        elapsed = bound(elapsed, 1, 365 days);

        // Deploy a fresh harness with the fuzzed fee percentage
        harness = new VaultWrapperHarness(
            address(underlyingVault), feePct
        );

        // Seed the underlying vault with assets owned by the harness
        // so totalAssets() returns a meaningful value.
        // Mint asset tokens, deposit them into the underlying vault
        // on behalf of the harness.
        uint256 seedAssets = aum;
        asset.mint(address(this), seedAssets);
        asset.approve(address(underlyingVault), seedAssets);
        underlyingVault.deposit(seedAssets, address(harness));

        // Mint real wrapper shares equal to the seed so the 1:1 ratio holds
        harness.exposed_mint(address(this), seedAssets);

        // Set fee collector state: AUM = aum, timestamp in the past
        uint256 startTime = block.timestamp;
        harness.exposed_setFeeCollectorState(
            FEE_COLLECTOR, aum, startTime, 0
        );

        // Warp forward by elapsed seconds
        vm.warp(startTime + elapsed);

        // Compute expected fee assets
        // feeAssets = aum * feePct * elapsed / (10000 * 31557600)
        uint256 feeAssets = Math.mulDiv(
            aum * feePct,
            elapsed,
            10000 * 31557600
        );

        // Compute expected shares using the base supply ratio
        uint256 totalAssetsVal = harness.totalAssets();
        uint256 baseSupply = harness.totalSupply()
            + harness.totalSettledVirtualShares();

        uint256 expectedShares;
        if (feeAssets == 0) {
            expectedShares = 0;
        } else if (totalAssetsVal == 0 || baseSupply == 0) {
            expectedShares = feeAssets;
        } else {
            expectedShares = Math.mulDiv(
                feeAssets, baseSupply, totalAssetsVal, Math.Rounding.Floor
            );
        }

        uint256 actual = harness.getPendingVirtualShares(FEE_COLLECTOR);

        // Allow 1 wei tolerance for rounding
        assertApproxEqAbs(
            actual,
            expectedShares,
            1,
            "Pending virtual shares should match formula"
        );
    }
}

// ---------------------------------------------------------------
// Feature: safe-4626-vault-module, Property 5: Effective Total Supply Invariant
// **Validates: Requirements 2.7, 4.2**
// ---------------------------------------------------------------

contract VaultWrapperEffectiveTotalSupplyTest is Test {
    MockERC20 public asset;
    MockERC4626 public underlyingVault;
    VaultWrapperHarness public harness;

    address constant FEE_COLLECTOR = address(0xFEE);

    function setUp() public {
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(
            IERC20(address(asset)), "Test Vault", "vTT"
        );
        // 100 bps (1%) annual fee
        harness = new VaultWrapperHarness(address(underlyingVault), 100);
    }

    function testFuzz_effectiveTotalSupplyInvariant(
        uint256 realShares,
        uint256 settled,
        uint256 aum,
        uint256 elapsed
    ) public {
        // Bound inputs
        realShares = bound(realShares, 0, 1e24);
        settled = bound(settled, 0, 1e24);
        aum = bound(aum, 0, 1e30);
        elapsed = bound(elapsed, 0, 365 days);

        // Mint real wrapper shares
        if (realShares > 0) {
            harness.exposed_mint(address(this), realShares);
        }

        // Set global settled virtual shares
        harness.exposed_setTotalSettledVirtualShares(settled);

        // Deposit real assets into the underlying vault on behalf of
        // the harness so totalAssets() returns something meaningful
        // (needed when aum > 0 so getPendingVirtualShares can convert)
        if (aum > 0) {
            asset.mint(address(this), aum);
            asset.approve(address(underlyingVault), aum);
            underlyingVault.deposit(aum, address(harness));
        }

        // Set fee collector state with AUM and a past timestamp
        uint256 startTime = block.timestamp;
        if (aum > 0 && elapsed > 0) {
            harness.exposed_setFeeCollectorState(
                FEE_COLLECTOR, aum, startTime, 0
            );
            vm.warp(startTime + elapsed);
        }

        // Compute expected: totalSupply + settled + pending
        uint256 pendingShares = harness.getPendingVirtualShares(
            FEE_COLLECTOR
        );
        uint256 expected = harness.totalSupply()
            + harness.totalSettledVirtualShares()
            + pendingShares;

        uint256 actual = harness.effectiveTotalSupply();

        assertEq(
            actual,
            expected,
            "effectiveTotalSupply must equal totalSupply + settled + pending"
        );
    }
}


// ===============================================================
// Deposit / Withdraw property tests
// ===============================================================

contract VaultWrapperDepositWithdrawTest is Test {
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
        // Deploy wrapper with 100 bps (1%) annual fee
        wrapper = VaultWrapper(
            factory.deploy(address(underlyingVault), 100)
        );
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 4: Deposit Mints Correct Shares
    // **Validates: Requirements 2.3**
    // ---------------------------------------------------------------

    function testFuzz_depositMintsCorrectShares(uint256 assets) public {
        assets = bound(assets, 1e6, 1e24);

        // Fund DEPOSITOR with asset tokens
        asset.mint(DEPOSITOR, assets);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), assets);

        // Snapshot expected shares BEFORE deposit
        uint256 expectedShares = wrapper.convertToShares(assets);

        wrapper.deposit(assets, DEPOSITOR, FEE_COLLECTOR);
        vm.stopPrank();

        assertEq(
            wrapper.balanceOf(DEPOSITOR),
            expectedShares,
            "Minted shares must equal convertToShares snapshot before deposit"
        );
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 8: Settlement on Position Change
    // **Validates: Requirements 4.5, 6.6, 7.4**
    // ---------------------------------------------------------------

    function testFuzz_settlementOnPositionChange(
        uint256 depositAmount,
        uint256 warpTime
    ) public {
        depositAmount = bound(depositAmount, 1e18, 1e24);
        warpTime = bound(warpTime, 1, 365 days);

        // First deposit
        asset.mint(DEPOSITOR, depositAmount + 1e18);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount + 1e18);
        wrapper.deposit(depositAmount, DEPOSITOR, FEE_COLLECTOR);
        vm.stopPrank();

        // Warp forward so virtual fees accrue
        vm.warp(block.timestamp + warpTime);

        // Record settled virtual shares before second deposit
        (,uint256 settledBefore,,) = wrapper.getFeeCollectorState(FEE_COLLECTOR);

        // Second deposit triggers settlement
        vm.startPrank(DEPOSITOR);
        wrapper.deposit(1e18, DEPOSITOR, FEE_COLLECTOR);
        vm.stopPrank();

        (, uint256 settledAfter, uint256 pendingAfter,) =
            wrapper.getFeeCollectorState(FEE_COLLECTOR);

        // Settled virtual shares must have increased from the accrued fees
        assertGt(
            settledAfter,
            settledBefore,
            "Settled virtual shares must increase after position change"
        );

        // Pending should be zero right after settlement (timestamp just reset)
        assertEq(
            pendingAfter,
            0,
            "Pending virtual shares must be zero immediately after settlement"
        );
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 9: Fee Collector Assignment and AUM Tracking
    // **Validates: Requirements 5.1, 5.2, 5.3**
    // ---------------------------------------------------------------

    function testFuzz_feeCollectorAssignmentAndAUM(
        uint256 deposit1,
        uint256 deposit2
    ) public {
        deposit1 = bound(deposit1, 1e18, 1e24);
        deposit2 = bound(deposit2, 1e18, 1e24);

        address FC1 = address(0xFC01);
        address FC2 = address(0xFC02);

        // Total tokens needed: deposit1 + deposit1 + deposit2 (three deposits)
        uint256 totalNeeded = deposit1 + deposit1 + deposit2;
        asset.mint(DEPOSITOR, totalNeeded);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), totalNeeded);

        // --- Scenario 1: New depositor with FC1 ---
        wrapper.deposit(deposit1, DEPOSITOR, FC1);

        assertEq(
            wrapper.depositorFeeCollector(DEPOSITOR),
            FC1,
            "New depositor must be assigned to FC1"
        );
        (uint256 aumFC1_1,,,) = wrapper.getFeeCollectorState(FC1);
        assertEq(aumFC1_1, deposit1, "FC1 AUM must equal first deposit");

        // --- Scenario 2: Same collector FC1, deposit again ---
        wrapper.deposit(deposit1, DEPOSITOR, FC1);

        (uint256 aumFC1_2,,,) = wrapper.getFeeCollectorState(FC1);
        assertEq(
            aumFC1_2,
            deposit1 + deposit1,
            "FC1 AUM must increase by second deposit"
        );

        // --- Scenario 3: Rotation to FC2 ---
        (uint256 aumFC1Before,,,) = wrapper.getFeeCollectorState(FC1);
        (uint256 aumFC2Before,,,) = wrapper.getFeeCollectorState(FC2);

        wrapper.deposit(deposit2, DEPOSITOR, FC2);

        (uint256 aumFC1After,,,) = wrapper.getFeeCollectorState(FC1);
        (uint256 aumFC2After,,,) = wrapper.getFeeCollectorState(FC2);

        assertEq(
            wrapper.depositorFeeCollector(DEPOSITOR),
            FC2,
            "Depositor must now be assigned to FC2"
        );
        assertLt(
            aumFC1After,
            aumFC1Before,
            "Old FC1 AUM must decrease after rotation"
        );
        assertGt(
            aumFC2After,
            aumFC2Before,
            "New FC2 AUM must increase after rotation"
        );

        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 23: Deposit-Withdraw Round Trip
    // **Validates: Requirements 2.2, 2.4**
    // ---------------------------------------------------------------

    function testFuzz_depositWithdrawRoundTrip(uint256 assets) public {
        assets = bound(assets, 1e6, 1e24);

        asset.mint(DEPOSITOR, assets);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), assets);

        // Deposit
        uint256 shares = wrapper.deposit(assets, DEPOSITOR, FEE_COLLECTOR);

        // Immediately redeem ALL shares (no time warp — no fee accrual)
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        // Returned assets should match deposited within 2 wei (underlying vault rounding)
        assertApproxEqAbs(
            returned,
            assets,
            2,
            "Round-trip must return deposited assets within 2 wei tolerance"
        );
    }
}


// ===============================================================
// Fee Collection property tests
// ===============================================================

// ---------------------------------------------------------------
// Feature: safe-4626-vault-module, Property 10: Fee Collection Transfers to Collector
// **Validates: Requirements 6.1, 6.2**
// ---------------------------------------------------------------

contract VaultWrapperFeeCollectionTest is Test {
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
        // 100 bps (1%) annual fee
        wrapper = VaultWrapper(
            factory.deploy(address(underlyingVault), 100)
        );
    }

    function testFuzz_feeCollectionTransfersToCollector(
        uint256 depositAmount,
        uint256 warpTime
    ) public {
        depositAmount = bound(depositAmount, 1e18, 1e24);
        warpTime = bound(warpTime, 1 days, 365 days);

        // Deposit as DEPOSITOR with FEE_COLLECTOR
        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR, FEE_COLLECTOR);
        vm.stopPrank();

        // Warp forward so fees accrue
        vm.warp(block.timestamp + warpTime);

        // Record balances before collection
        uint256 collectorBalBefore = asset.balanceOf(FEE_COLLECTOR);
        address caller = address(0xCAFE);
        uint256 callerBalBefore = asset.balanceOf(caller);

        // Anyone can call collectFees — permissionless
        vm.prank(caller);
        wrapper.collectFees(FEE_COLLECTOR);

        // Fee collector must have received assets
        uint256 collectorBalAfter = asset.balanceOf(FEE_COLLECTOR);
        assertGt(
            collectorBalAfter,
            collectorBalBefore,
            "Fee collector balance must increase after fee collection"
        );

        // Caller's balance must not change (caller != feeCollector)
        uint256 callerBalAfter = asset.balanceOf(caller);
        assertEq(
            callerBalAfter,
            callerBalBefore,
            "Caller balance must not change - assets go only to fee collector"
        );
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 11: Fee Collection Preserves Real Total Supply
    // **Validates: Requirements 6.4**
    // ---------------------------------------------------------------

    function testFuzz_feeCollectionPreservesRealTotalSupply(
        uint256 depositAmount,
        uint256 warpTime
    ) public {
        depositAmount = bound(depositAmount, 1e18, 1e24);
        warpTime = bound(warpTime, 1 days, 365 days);

        // Deposit
        asset.mint(DEPOSITOR, depositAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR, FEE_COLLECTOR);
        vm.stopPrank();

        // Warp forward
        vm.warp(block.timestamp + warpTime);

        // Record real totalSupply before
        uint256 supplyBefore = wrapper.totalSupply();

        // Collect fees
        wrapper.collectFees(FEE_COLLECTOR);

        // Real totalSupply must be unchanged — minted shares are immediately
        // redeemed and burned, so net effect on real supply is zero
        uint256 supplyAfter = wrapper.totalSupply();
        assertEq(
            supplyAfter,
            supplyBefore,
            "Real totalSupply must be unchanged after fee collection"
        );
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 12: Global Settled Virtual Shares Consistency
    // **Validates: Requirements 7.3**
    // ---------------------------------------------------------------

    function testFuzz_globalSettledVirtualSharesConsistency(
        uint256 deposit1,
        uint256 deposit2,
        uint256 warpTime
    ) public {
        deposit1 = bound(deposit1, 1e18, 1e24);
        deposit2 = bound(deposit2, 1e18, 1e24);
        warpTime = bound(warpTime, 1 days, 365 days);

        address fc1 = address(0xFC01);
        address fc2 = address(0xFC02);
        address depositor1 = address(0xD001);
        address depositor2 = address(0xD002);

        // Deposit with two different fee collectors
        asset.mint(depositor1, deposit1 * 2);
        vm.startPrank(depositor1);
        asset.approve(address(wrapper), deposit1 * 2);
        wrapper.deposit(deposit1, depositor1, fc1);
        vm.stopPrank();

        asset.mint(depositor2, deposit2 * 2);
        vm.startPrank(depositor2);
        asset.approve(address(wrapper), deposit2 * 2);
        wrapper.deposit(deposit2, depositor2, fc2);
        vm.stopPrank();

        // Warp forward so fees accrue
        vm.warp(block.timestamp + warpTime);

        // Trigger settlement by doing another deposit for each
        vm.startPrank(depositor1);
        wrapper.deposit(deposit1, depositor1, fc1);
        vm.stopPrank();

        vm.startPrank(depositor2);
        wrapper.deposit(deposit2, depositor2, fc2);
        vm.stopPrank();

        // Read individual settled virtual shares
        (, uint256 settledFc1,,) = wrapper.getFeeCollectorState(fc1);
        (, uint256 settledFc2,,) = wrapper.getFeeCollectorState(fc2);

        // Global must equal sum of individuals
        uint256 globalSettled = wrapper.totalSettledVirtualShares();
        assertEq(
            globalSettled,
            settledFc1 + settledFc2,
            "Global settled virtual shares must equal sum of individual fee collector settled shares"
        );
    }
}
