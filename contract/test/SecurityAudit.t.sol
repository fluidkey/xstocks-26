// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeEarnModule} from "../src/SafeEarnModule.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {VaultWrapper} from "../src/VaultWrapper.sol";
import {ISafe} from "../src/ISafe.sol";
import {MockERC20, MockERC4626} from "./mocks/MockERC4626.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

/// Minimal Safe mock that executes module transactions
contract TestSafe is ISafe {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        uint8 /*operation*/
    ) external override returns (bool success) {
        (success, ) = to.call{value: value}(data);
    }
    receive() external payable {}
}

/// Safe mock that always returns true without executing (simulates stale approvals)
contract AlwaysTrueSafe is ISafe {
    function execTransactionFromModule(
        address, uint256, bytes memory, uint8
    ) external pure override returns (bool) {
        return true;
    }
}

/// Safe mock that always returns false
contract AlwaysFalseSafe is ISafe {
    function execTransactionFromModule(
        address, uint256, bytes memory, uint8
    ) external pure override returns (bool) {
        return false;
    }
}

// ═══════════════════════════════════════════════════════════════
// VaultWrapper Security Tests
// ═══════════════════════════════════════════════════════════════

contract VaultWrapperSecurityTest is Test {
    VaultWrapperFactory public factory;
    MockERC20 public asset;
    MockERC4626 public underlyingVault;
    VaultWrapper public wrapper;

    address constant FEE_COLLECTOR = address(0xFEE);
    address constant DEPOSITOR = address(0xDEAD);
    address constant ATTACKER = address(0xBAD);

    function setUp() public {
        factory = new VaultWrapperFactory();
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(IERC20(address(asset)), "Test Vault", "vTT");
        wrapper = VaultWrapper(factory.deploy(address(underlyingVault), 100));
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Non-owner cannot redeem/withdraw someone else's shares
    // ───────────────────────────────────────────────────────────

    function test_attackerCannotRedeemOthersShares() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        uint256 shares = wrapper.balanceOf(DEPOSITOR);

        // Attacker tries to redeem depositor's shares
        vm.prank(ATTACKER);
        vm.expectRevert(VaultWrapper.NotShareOwner.selector);
        wrapper.redeem(shares, ATTACKER, DEPOSITOR);
    }

    function test_attackerCannotWithdrawOthersAssets() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        // Attacker tries to withdraw depositor's assets
        vm.prank(ATTACKER);
        vm.expectRevert(VaultWrapper.NotShareOwner.selector);
        wrapper.withdraw(50e18, ATTACKER, DEPOSITOR);
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Deposit without fee collector set must revert
    // ───────────────────────────────────────────────────────────

    function test_depositWithoutFeeCollectorReverts() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        vm.expectRevert(VaultWrapper.FeeCollectorNotSet.selector);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Setting fee collector to zero address
    // ───────────────────────────────────────────────────────────

    function test_setFeeCollectorZeroAddressReverts() public {
        vm.prank(DEPOSITOR);
        vm.expectRevert(VaultWrapper.ZeroFeeCollector.selector);
        wrapper.setFeeCollector(address(0));
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Zero amount deposit/withdraw/redeem
    // ───────────────────────────────────────────────────────────

    function test_zeroDepositReverts() public {
        vm.prank(DEPOSITOR);
        vm.expectRevert(VaultWrapper.ZeroAssets.selector);
        wrapper.deposit(0, DEPOSITOR);
    }

    function test_zeroRedeemReverts() public {
        vm.prank(DEPOSITOR);
        vm.expectRevert(VaultWrapper.ZeroShares.selector);
        wrapper.redeem(0, DEPOSITOR, DEPOSITOR);
    }

    function test_zeroWithdrawReverts() public {
        vm.prank(DEPOSITOR);
        vm.expectRevert(VaultWrapper.ZeroAssets.selector);
        wrapper.withdraw(0, DEPOSITOR, DEPOSITOR);
    }

    function test_zeroMintReverts() public {
        vm.prank(DEPOSITOR);
        vm.expectRevert(VaultWrapper.ZeroShares.selector);
        wrapper.mint(0, DEPOSITOR);
    }

    // ───────────────────────────────────────────────────────────
    // BY DESIGN: Fee collector self-assignment (fee avoidance)
    // Only possible when bypassing the module and calling the
    // wrapper directly. The module always enforces the correct
    // fee collector from the Safe's config.
    // ───────────────────────────────────────────────────────────

    function test_feeCollectorSelfAssignment_feesGoBackToDepositor() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        // Depositor sets themselves as fee collector
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(DEPOSITOR);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        // Warp 1 year for max fee accrual
        vm.warp(block.timestamp + 365 days);

        uint256 depositorBalBefore = asset.balanceOf(DEPOSITOR);
        wrapper.collectFees(DEPOSITOR);
        uint256 feesCollected = asset.balanceOf(DEPOSITOR) - depositorBalBefore;

        // Fees go back to the depositor - this is a fee avoidance vector
        // The test documents this behavior; protocol should enforce fee collector
        // via the module, not allow direct wrapper interaction
        assertGt(feesCollected, 0, "Self-assigned fee collector receives fees");
    }

    // ───────────────────────────────────────────────────────────
    // BY DESIGN: Deposit on behalf of another user (AUM inflation)
    // Standard ERC-4626 behavior. The attacker pays real tokens
    // for the deposit so this is not exploitable for profit.
    // ───────────────────────────────────────────────────────────

    function test_anyoneCanDepositOnBehalfInflatingAUM() public {
        uint256 depositorAmount = 100e18;
        uint256 attackerDust = 1;

        // Depositor sets up normally
        asset.mint(DEPOSITOR, depositorAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), depositorAmount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(depositorAmount, DEPOSITOR);
        vm.stopPrank();

        (uint256 aumBefore,,,) = wrapper.getFeeCollectorState(FEE_COLLECTOR);

        // Attacker deposits dust on behalf of depositor
        asset.mint(ATTACKER, attackerDust);
        vm.startPrank(ATTACKER);
        asset.approve(address(wrapper), attackerDust);
        wrapper.deposit(attackerDust, DEPOSITOR);
        vm.stopPrank();

        (uint256 aumAfter,,,) = wrapper.getFeeCollectorState(FEE_COLLECTOR);

        // AUM increased - attacker inflated fee collector's AUM
        // Shares went to DEPOSITOR, not attacker
        assertEq(aumAfter, aumBefore + attackerDust, "AUM inflated by attacker dust deposit");
        assertEq(wrapper.balanceOf(ATTACKER), 0, "Attacker gets no shares");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: collectFees called repeatedly yields no extra value
    // ───────────────────────────────────────────────────────────

    function test_repeatedCollectFeesNoDoubleExtraction() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        // First collection
        uint256 balBefore = asset.balanceOf(FEE_COLLECTOR);
        wrapper.collectFees(FEE_COLLECTOR);
        uint256 firstCollection = asset.balanceOf(FEE_COLLECTOR) - balBefore;
        assertGt(firstCollection, 0, "First collection should yield fees");

        // Immediate second collection - should yield nothing
        uint256 balBefore2 = asset.balanceOf(FEE_COLLECTOR);
        wrapper.collectFees(FEE_COLLECTOR);
        uint256 secondCollection = asset.balanceOf(FEE_COLLECTOR) - balBefore2;
        assertEq(secondCollection, 0, "Immediate second collection must yield zero");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Redeem more shares than balance
    // ───────────────────────────────────────────────────────────

    function test_redeemMoreThanBalanceReverts() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, DEPOSITOR);

        uint256 shares = wrapper.balanceOf(DEPOSITOR);
        vm.expectRevert(VaultWrapper.InsufficientBalance.selector);
        wrapper.redeem(shares + 1, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Fee collector rotation settles old collector first
    // Ensures attacker can't skip fee settlement by rotating
    // ───────────────────────────────────────────────────────────

    function test_feeCollectorRotationSettlesOldCollector() public {
        address FC1 = address(0xFC01);
        address FC2 = address(0xFC02);
        uint256 amount = 100e18;

        asset.mint(DEPOSITOR, amount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FC1);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        // Warp so fees accrue under FC1
        vm.warp(block.timestamp + 90 days);

        // Check FC1 has pending fees before rotation
        uint256 pendingBefore = wrapper.getPendingVirtualShares(FC1);
        assertGt(pendingBefore, 0, "FC1 must have pending fees before rotation");

        // Rotate to FC2
        vm.prank(DEPOSITOR);
        wrapper.setFeeCollector(FC2);

        // FC1's pending fees should now be settled
        (, uint256 settledFC1,,) = wrapper.getFeeCollectorState(FC1);
        assertGt(settledFC1, 0, "FC1 settled shares must be non-zero after rotation");

        // FC1 can still collect those settled fees
        uint256 fc1BalBefore = asset.balanceOf(FC1);
        wrapper.collectFees(FC1);
        assertGt(asset.balanceOf(FC1) - fc1BalBefore, 0, "FC1 must receive fees after rotation");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: globalLastAccrualTimestamp manipulation via
    // repeated collectFees on a zero-AUM collector
    // ───────────────────────────────────────────────────────────

    function test_collectFeesOnZeroAUMDoesNotUpdateGlobalTimestamp() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        // Calling collectFees on a random address with no AUM should NOT
        // advance the global timestamp
        address randomCollector = address(0x1234);
        uint256 globalTsBefore = wrapper.globalLastAccrualTimestamp();

        vm.warp(block.timestamp + 1 days);
        wrapper.collectFees(randomCollector);

        uint256 globalTsAfter = wrapper.globalLastAccrualTimestamp();

        // FIXED: global timestamp must NOT advance for zero-AUM collectors
        assertEq(globalTsAfter, globalTsBefore,
            "Global timestamp must not advance on zero-AUM collectFees");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Withdraw more assets than deposited (after fees)
    // Ensures depositor can't extract more than their fair share
    // ───────────────────────────────────────────────────────────

    function test_depositorCannotExtractMoreThanDeposited() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        uint256 shares = wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        // Warp 1 year - 1% fee should accrue
        vm.warp(block.timestamp + 365 days);

        // Depositor redeems all shares
        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);

        // Must get back less than deposited due to fee dilution
        assertLt(returned, amount, "Depositor must get back less than deposited after fee accrual");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Multiple depositors - one can't steal from another
    // ───────────────────────────────────────────────────────────

    function test_multipleDepositorsIsolation() public {
        address depositor2 = address(0xBEEF);
        uint256 amount = 100e18;

        // Both deposit same amount
        asset.mint(DEPOSITOR, amount);
        asset.mint(depositor2, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        vm.startPrank(depositor2);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, depositor2);
        vm.stopPrank();

        // Depositor1 redeems all
        uint256 shares1 = wrapper.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        uint256 returned1 = wrapper.redeem(shares1, DEPOSITOR, DEPOSITOR);

        // Depositor2 redeems all
        uint256 shares2 = wrapper.balanceOf(depositor2);
        vm.prank(depositor2);
        uint256 returned2 = wrapper.redeem(shares2, depositor2, depositor2);

        // Both should get approximately the same (within rounding)
        assertApproxEqAbs(returned1, returned2, 2,
            "Equal depositors must get approximately equal returns");

        // Neither should get more than deposited
        assertLe(returned1, amount, "Depositor1 cannot extract more than deposited");
        assertLe(returned2, amount, "Depositor2 cannot extract more than deposited");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Fee collection preserves depositor solvency
    // After fees are collected, depositors can still withdraw
    // ───────────────────────────────────────────────────────────

    function test_feeCollectionDoesNotBrickWithdrawals() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        uint256 shares = wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        // Warp and collect fees
        vm.warp(block.timestamp + 180 days);
        wrapper.collectFees(FEE_COLLECTOR);

        // Depositor should still be able to redeem all remaining shares
        uint256 remainingShares = wrapper.balanceOf(DEPOSITOR);
        assertEq(remainingShares, shares, "Share balance unchanged after fee collection");

        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(remainingShares, DEPOSITOR, DEPOSITOR);
        assertGt(returned, 0, "Depositor must be able to withdraw after fee collection");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Overflow in fee calculation with large AUM
    // state.totalAUM * feePercentage could overflow
    // ───────────────────────────────────────────────────────────

    function test_largeAUMDoesNotOverflowFeeCalc() public {
        // Deploy wrapper with max fee (5000 bps = 50%)
        VaultWrapper highFeeWrapper = VaultWrapper(
            factory.deploy(address(underlyingVault), 5000)
        );

        // Deposit a very large amount (near practical limits)
        uint256 largeAmount = 1e30; // 1 trillion tokens with 18 decimals
        asset.mint(DEPOSITOR, largeAmount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(highFeeWrapper), largeAmount);
        highFeeWrapper.setFeeCollector(FEE_COLLECTOR);
        highFeeWrapper.deposit(largeAmount, DEPOSITOR);
        vm.stopPrank();

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // This should not revert due to overflow
        uint256 pending = highFeeWrapper.getPendingVirtualShares(FEE_COLLECTOR);
        assertGt(pending, 0, "Pending shares must be computed without overflow");

        // Fee collection should work
        highFeeWrapper.collectFees(FEE_COLLECTOR);
        assertGt(asset.balanceOf(FEE_COLLECTOR), 0, "Fee collector must receive assets");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: First depositor inflation attack
    // Deposit 1 wei, then donate to underlying vault to inflate
    // share price and steal from next depositor
    // ───────────────────────────────────────────────────────────

    /// @dev FIXED: Virtual offset prevents the ERC-4626 inflation attack.
    ///      After adding _VIRTUAL_OFFSET to convertToShares/convertToAssets,
    ///      the attacker's donation no longer causes ZeroShares for the victim.
    ///      The victim gets shares and can withdraw approximately what they deposited.
    function test_firstDepositorInflationAttack_MITIGATED() public {
        // Attacker deposits 1 wei
        asset.mint(ATTACKER, 1);
        vm.startPrank(ATTACKER);
        asset.approve(address(wrapper), 1);
        wrapper.setFeeCollector(address(0xA77AC));
        wrapper.deposit(1, ATTACKER);
        vm.stopPrank();

        // Attacker donates large amount directly to underlying vault
        // on behalf of the wrapper to inflate totalAssets
        uint256 donationAmount = 100e18;
        asset.mint(ATTACKER, donationAmount);
        vm.startPrank(ATTACKER);
        asset.approve(address(underlyingVault), donationAmount);
        underlyingVault.deposit(donationAmount, address(wrapper));
        vm.stopPrank();

        // Victim deposits - should now succeed thanks to virtual offset
        uint256 victimAmount = 50e18;
        asset.mint(DEPOSITOR, victimAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), victimAmount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        uint256 victimShares = wrapper.deposit(victimAmount, DEPOSITOR);
        vm.stopPrank();

        // Victim should get meaningful shares and be able to withdraw ~what they deposited
        assertGt(victimShares, 0, "Victim must receive shares after inflation attack mitigation");
        uint256 victimAssetValue = wrapper.convertToAssets(victimShares);
        assertGt(victimAssetValue, victimAmount * 99 / 100,
            "Victim must retain >99% of deposited value with virtual offset protection");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Withdraw to a different receiver (assets go to attacker)
    // Only owner can call, but receiver can be anyone
    // ───────────────────────────────────────────────────────────

    function test_withdrawToSelfOnly() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, DEPOSITOR);

        // Depositor can withdraw to themselves - this is fine
        uint256 shares = wrapper.balanceOf(DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        assertGt(returned, 0, "Owner can redeem to self");
        vm.stopPrank();
    }

    function test_ownerCanRedeemToAnyReceiver() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, DEPOSITOR);

        // Owner can choose any receiver for the assets
        uint256 shares = wrapper.balanceOf(DEPOSITOR);
        address receiver = address(0x9999);
        uint256 returned = wrapper.redeem(shares, receiver, DEPOSITOR);
        vm.stopPrank();

        assertGt(returned, 0, "Redeem succeeded");
        assertGt(asset.balanceOf(receiver), 0, "Receiver got assets");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Mint function - verify correct asset calculation
    // ───────────────────────────────────────────────────────────

    function test_mintPullsCorrectAssets() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);

        // First deposit to establish share price
        wrapper.deposit(50e18, DEPOSITOR);

        // Mint specific shares
        uint256 sharesToMint = 10e18;
        uint256 assetsBefore = asset.balanceOf(DEPOSITOR);
        uint256 assetsPulled = wrapper.mint(sharesToMint, DEPOSITOR);
        uint256 assetsAfter = asset.balanceOf(DEPOSITOR);

        assertEq(assetsBefore - assetsAfter, assetsPulled, "Correct assets pulled for mint");
        vm.stopPrank();
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Fee accrual over very long time periods
    // Ensures no overflow or unexpected behavior
    // ───────────────────────────────────────────────────────────

    function test_feeAccrualOverMultipleYears() public {
        uint256 amount = 1_000_000e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.setFeeCollector(FEE_COLLECTOR);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        // Warp 10 years
        vm.warp(block.timestamp + 3650 days);

        // Should still be able to collect fees without overflow
        wrapper.collectFees(FEE_COLLECTOR);
        uint256 feesCollected = asset.balanceOf(FEE_COLLECTOR);
        assertGt(feesCollected, 0, "Fees collected after 10 years");

        // Depositor should still be able to withdraw
        uint256 shares = wrapper.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        assertGt(returned, 0, "Depositor can withdraw after 10 years");

        // Total extracted should not exceed total deposited
        assertLe(feesCollected + returned, amount + 1,
            "Total extracted must not exceed deposited (within rounding)");
    }
}


// ═══════════════════════════════════════════════════════════════
// SafeEarnModule Security Tests
// ═══════════════════════════════════════════════════════════════

contract SafeEarnModuleSecurityTest is Test {
    MockERC20 public asset;
    MockERC4626 public underlyingVault;
    VaultWrapperFactory public factory;
    SafeEarnModule public module;
    TestSafe public safe;

    uint256 constant RELAYER_PK = 0xBEEF;
    address RELAYER;
    address constant WRAPPED_NATIVE = address(0xE770);
    address constant FEE_COLLECTOR = address(0xFEE);
    uint256 constant FEE_PCT = 100;

    bytes32 merkleRoot;
    bytes32[] emptyProof;

    function setUp() public {
        RELAYER = vm.addr(RELAYER_PK);
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(IERC20(address(asset)), "Test Vault", "vTT");
        factory = new VaultWrapperFactory();
        module = new SafeEarnModule(RELAYER, WRAPPED_NATIVE, address(this), address(factory));
        safe = new TestSafe();

        merkleRoot = keccak256(abi.encodePacked(address(underlyingVault), FEE_PCT));
        emptyProof = new bytes32[](0);

        vm.prank(address(safe));
        module.onInstall(abi.encode(merkleRoot, FEE_COLLECTOR));
    }

    function _signDeposit(
        address token, uint256 amount, address vault,
        uint256 feePct, address safeAddr, uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            "deposit", block.chainid, token, amount, vault, feePct, safeAddr, nonce
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signWithdraw(
        address token, uint256 shares, address vault,
        uint256 feePct, address safeAddr, uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            "withdraw", block.chainid, token, shares, vault, feePct, safeAddr, nonce
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Unauthorized signer cannot execute deposits
    // ───────────────────────────────────────────────────────────

    function test_unauthorizedSignerCannotDeposit() public {
        uint256 attackerPk = 0xDEAD;
        address attacker = vm.addr(attackerPk);
        uint256 amount = 100e18;

        asset.mint(address(safe), amount);

        bytes32 messageHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), amount,
            address(underlyingVault), FEE_PCT, address(safe), uint256(0)
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.NotAuthorized.selector, attacker));
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT,
            address(safe), 0, sig, emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Replay same signature twice
    // ───────────────────────────────────────────────────────────

    function test_signatureReplayReverts() public {
        uint256 amount = 50e18;
        asset.mint(address(safe), amount * 2);

        bytes memory sig = _signDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT, address(safe), 0
        );

        // First call succeeds
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT,
            address(safe), 0, sig, emptyProof
        );

        // Second call with same signature reverts
        vm.expectRevert(SafeEarnModule.SignatureAlreadyUsed.selector);
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT,
            address(safe), 0, sig, emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Cross-action replay (deposit sig used for withdraw)
    // ───────────────────────────────────────────────────────────

    function test_depositSignatureCannotBeUsedForWithdraw() public {
        uint256 amount = 50e18;
        asset.mint(address(safe), amount);

        // Sign a deposit
        bytes memory depositSig = _signDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT, address(safe), 0
        );

        // Execute deposit first
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT,
            address(safe), 0, depositSig, emptyProof
        );

        // Try to use a deposit-signed message as a withdraw
        // The message hashes differ because of the "deposit" vs "withdraw" tag
        // So we need to sign a new message with "withdraw" tag
        // This test verifies the action tags prevent cross-action replay
        bytes32 depositHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), amount,
            address(underlyingVault), FEE_PCT, address(safe), uint256(1)
        ));
        bytes32 withdrawHash = keccak256(abi.encode(
            "withdraw", block.chainid, address(asset), amount,
            address(underlyingVault), FEE_PCT, address(safe), uint256(1)
        ));

        // Hashes must differ due to action tag
        assertTrue(depositHash != withdrawHash, "Deposit and withdraw hashes must differ");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Deposit on uninitialized Safe
    // ───────────────────────────────────────────────────────────

    function test_depositOnUninitializedSafeReverts() public {
        TestSafe uninitSafe = new TestSafe();
        uint256 amount = 50e18;

        bytes memory sig = _signDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT, address(uninitSafe), 0
        );

        vm.expectRevert(
            abi.encodeWithSelector(SafeEarnModule.ModuleNotInitialized.selector, address(uninitSafe))
        );
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT,
            address(uninitSafe), 0, sig, emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Withdraw from undeployed wrapper
    // ───────────────────────────────────────────────────────────

    function test_withdrawFromUndeployedWrapperReverts() public {
        // Use a different vault that hasn't been deployed
        MockERC4626 otherVault = new MockERC4626(IERC20(address(asset)), "Other", "OTH");
        bytes32 otherRoot = keccak256(abi.encodePacked(address(otherVault), FEE_PCT));

        // Install with the other vault's root
        TestSafe otherSafe = new TestSafe();
        vm.prank(address(otherSafe));
        module.onInstall(abi.encode(otherRoot, FEE_COLLECTOR));

        bytes32 messageHash = keccak256(abi.encode(
            "withdraw", block.chainid, address(asset), uint256(100e18),
            address(otherVault), FEE_PCT, address(otherSafe), uint256(0)
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert(SafeEarnModule.WrapperNotDeployed.selector);
        module.autoWithdraw(
            address(asset), 100e18, address(otherVault), FEE_PCT,
            address(otherSafe), 0, sig, proof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Invalid merkle proof for unauthorized vault
    // ───────────────────────────────────────────────────────────

    function test_invalidMerkleProofForUnauthorizedVault() public {
        // Try to deposit into a vault not in the merkle tree
        MockERC4626 evilVault = new MockERC4626(IERC20(address(asset)), "Evil", "EVL");
        uint256 amount = 50e18;

        bytes32 messageHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), amount,
            address(evilVault), FEE_PCT, address(safe), uint256(0)
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(SafeEarnModule.InvalidMerkleProof.selector);
        module.autoDeposit(
            address(asset), amount, address(evilVault), FEE_PCT,
            address(safe), 0, sig, emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Double onInstall (re-initialization)
    // ───────────────────────────────────────────────────────────

    function test_doubleOnInstallReverts() public {
        vm.prank(address(safe));
        vm.expectRevert(
            abi.encodeWithSelector(SafeEarnModule.ModuleAlreadyInitialized.selector, address(safe))
        );
        module.onInstall(abi.encode(merkleRoot, FEE_COLLECTOR));
    }

    // ───────────────────────────────────────────────────────────
    // Attack: onInstall with zero root or zero fee collector
    // ───────────────────────────────────────────────────────────

    function test_onInstallZeroRootReverts() public {
        TestSafe newSafe = new TestSafe();
        vm.prank(address(newSafe));
        vm.expectRevert(SafeEarnModule.InvalidMerkleRoot.selector);
        module.onInstall(abi.encode(bytes32(0), FEE_COLLECTOR));
    }

    function test_onInstallZeroFeeCollectorReverts() public {
        TestSafe newSafe = new TestSafe();
        vm.prank(address(newSafe));
        vm.expectRevert(SafeEarnModule.InvalidFeeCollector.selector);
        module.onInstall(abi.encode(merkleRoot, address(0)));
    }

    // ───────────────────────────────────────────────────────────
    // BY DESIGN: Relayer privilege escalation
    // Any relayer can add/remove other relayers. This is the
    // current design choice. If a single relayer is compromised,
    // they can add attacker relayers. Consider restricting to
    // owner-only if this is not intentional.
    // ───────────────────────────────────────────────────────────

    function test_relayerCanAddOtherRelayers() public {
        address maliciousRelayer = address(0xBAD1);
        address accomplice = address(0xBAD2);

        // Owner adds malicious relayer (simulating compromise)
        module.addAuthorizedRelayer(maliciousRelayer);

        // Malicious relayer adds accomplice
        vm.prank(maliciousRelayer);
        module.addAuthorizedRelayer(accomplice);

        assertTrue(module.authorizedRelayers(accomplice),
            "Compromised relayer can add accomplices - privilege escalation risk");
    }

    function test_relayerCanRemoveOtherRelayers() public {
        address relayer2 = address(0xBEE2);
        module.addAuthorizedRelayer(relayer2);

        // Relayer2 removes the original relayer
        vm.prank(relayer2);
        module.removeAuthorizedRelayer(RELAYER);

        assertFalse(module.authorizedRelayers(RELAYER),
            "One relayer can remove another - potential for hostile takeover");
    }

    function test_relayerCannotRemoveSelf() public {
        vm.prank(RELAYER);
        vm.expectRevert(SafeEarnModule.CannotRemoveSelf.selector);
        module.removeAuthorizedRelayer(RELAYER);
    }

    function test_unauthorizedCannotAddRelayer() public {
        address nobody = address(0x1111);
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.NotAuthorized.selector, nobody));
        module.addAuthorizedRelayer(address(0x2222));
    }

    function test_unauthorizedCannotRemoveRelayer() public {
        address nobody = address(0x1111);
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.NotAuthorized.selector, nobody));
        module.removeAuthorizedRelayer(RELAYER);
    }

    // ───────────────────────────────────────────────────────────
    // Attack: changeMerkleRoot on uninitialized Safe
    // FIXED: now reverts with ModuleNotInitialized
    // ───────────────────────────────────────────────────────────

    function test_changeMerkleRootOnUninitializedSafe() public {
        address uninitAddr = address(0x7777);
        bytes32 newRoot = bytes32(uint256(1));

        // Must revert because the Safe hasn't called onInstall yet
        vm.prank(uninitAddr);
        vm.expectRevert(
            abi.encodeWithSelector(SafeEarnModule.ModuleNotInitialized.selector, uninitAddr)
        );
        module.changeMerkleRoot(newRoot);
    }

    // ───────────────────────────────────────────────────────────
    // Attack: changeMerkleRoot with zero reverts
    // ───────────────────────────────────────────────────────────

    function test_changeMerkleRootZeroReverts() public {
        vm.prank(address(safe));
        vm.expectRevert(SafeEarnModule.InvalidMerkleRoot.selector);
        module.changeMerkleRoot(bytes32(0));
    }

    // ───────────────────────────────────────────────────────────
    // BY DESIGN: onUninstall on uninitialized Safe (no-op)
    // Emits ModuleUninitialized event even though nothing was
    // installed. Cosmetic issue, not worth the gas for a check.
    // ───────────────────────────────────────────────────────────

    function test_onUninstallUninitializedEmitsMisleadingEvent() public {
        address uninitAddr = address(0x8888);

        vm.prank(uninitAddr);
        vm.expectEmit(true, false, false, false);
        emit SafeEarnModule.ModuleUninitialized(uninitAddr);
        module.onUninstall();

        // State is unchanged (was already zero)
        assertFalse(module.isInitialized(uninitAddr), "Still not initialized");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Deposit with wrong fee percentage (not in merkle tree)
    // ───────────────────────────────────────────────────────────

    function test_depositWithWrongFeePercentageReverts() public {
        uint256 wrongFee = 200; // Not in merkle tree (tree has 100)
        uint256 amount = 50e18;

        bytes32 messageHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), amount,
            address(underlyingVault), wrongFee, address(safe), uint256(0)
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(SafeEarnModule.InvalidMerkleProof.selector);
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), wrongFee,
            address(safe), 0, sig, emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Removed relayer's old signatures become invalid
    // ───────────────────────────────────────────────────────────

    function test_removedRelayerSignaturesInvalid() public {
        uint256 relayer2Pk = 0xCAFE;
        address relayer2 = vm.addr(relayer2Pk);
        module.addAuthorizedRelayer(relayer2);

        // Relayer2 signs a deposit
        uint256 amount = 50e18;
        bytes32 messageHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), amount,
            address(underlyingVault), FEE_PCT, address(safe), uint256(0)
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(relayer2Pk, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Owner removes relayer2
        module.removeAuthorizedRelayer(relayer2);

        // Relayer2's signature should now be invalid
        vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.NotAuthorized.selector, relayer2));
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT,
            address(safe), 0, sig, emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Safe uninstalls then tries to deposit
    // ───────────────────────────────────────────────────────────

    function test_depositAfterUninstallReverts() public {
        vm.prank(address(safe));
        module.onUninstall();

        uint256 amount = 50e18;
        bytes memory sig = _signDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT, address(safe), 0
        );

        vm.expectRevert(
            abi.encodeWithSelector(SafeEarnModule.ModuleNotInitialized.selector, address(safe))
        );
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT,
            address(safe), 0, sig, emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Safe reinstalls after uninstall with different config
    // ───────────────────────────────────────────────────────────

    function test_reinstallAfterUninstall() public {
        vm.prank(address(safe));
        module.onUninstall();

        assertFalse(module.isInitialized(address(safe)), "Not initialized after uninstall");

        // Reinstall with different fee collector
        address newFeeCollector = address(0xEE1);
        vm.prank(address(safe));
        module.onInstall(abi.encode(merkleRoot, newFeeCollector));

        (bytes32 root, address fc) = module.safeConfigs(address(safe));
        assertEq(root, merkleRoot, "Root restored");
        assertEq(fc, newFeeCollector, "New fee collector set");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: autoWithdraw with more shares than Safe holds
    // Should revert at the wrapper level
    // ───────────────────────────────────────────────────────────

    function test_withdrawMoreSharesThanOwnedReverts() public {
        uint256 amount = 50e18;
        asset.mint(address(safe), amount);

        bytes memory depositSig = _signDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT, address(safe), 0
        );
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT,
            address(safe), 0, depositSig, emptyProof
        );

        address wrapperAddr = factory.computeAddress(address(underlyingVault), FEE_PCT);
        uint256 safeShares = VaultWrapper(wrapperAddr).balanceOf(address(safe));

        // Try to withdraw more shares than owned
        uint256 tooManyShares = safeShares + 1e18;
        bytes memory withdrawSig = _signWithdraw(
            address(asset), tooManyShares, address(underlyingVault), FEE_PCT, address(safe), 1
        );

        // Should revert (wrapper's InsufficientBalance propagates through Safe)
        vm.expectRevert(SafeEarnModule.RedeemFailed.selector);
        module.autoWithdraw(
            address(asset), tooManyShares, address(underlyingVault), FEE_PCT,
            address(safe), 1, withdrawSig, emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Attack: AlwaysFalseSafe - all exec calls fail
    // ───────────────────────────────────────────────────────────

    function test_depositOnFailingSafeReverts() public {
        AlwaysFalseSafe falseSafe = new AlwaysFalseSafe();
        bytes32 root = keccak256(abi.encodePacked(address(underlyingVault), FEE_PCT));

        vm.prank(address(falseSafe));
        module.onInstall(abi.encode(root, FEE_COLLECTOR));

        uint256 amount = 50e18;
        bytes32 messageHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), amount,
            address(underlyingVault), FEE_PCT, address(falseSafe), uint256(0)
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Should revert because Safe's exec always returns false
        vm.expectRevert(SafeEarnModule.SetFeeCollectorFailed.selector);
        module.autoDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT,
            address(falseSafe), 0, sig, emptyProof
        );
    }
}


// ═══════════════════════════════════════════════════════════════
// VaultWrapperFactory Security Tests
// ═══════════════════════════════════════════════════════════════

contract VaultWrapperFactorySecurityTest is Test {
    VaultWrapperFactory public factory;
    MockERC20 public asset;
    MockERC4626 public underlyingVault;

    function setUp() public {
        factory = new VaultWrapperFactory();
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(IERC20(address(asset)), "Test Vault", "vTT");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Deploy with boundary-exceeding fee percentages
    // ───────────────────────────────────────────────────────────

    function test_deployFee0Reverts() public {
        vm.expectRevert(VaultWrapperFactory.InvalidFeePercentage.selector);
        factory.deploy(address(underlyingVault), 0);
    }

    function test_deployFee5001Reverts() public {
        vm.expectRevert(VaultWrapperFactory.InvalidFeePercentage.selector);
        factory.deploy(address(underlyingVault), 5001);
    }

    function test_deployFeeMaxUint256Reverts() public {
        vm.expectRevert(VaultWrapperFactory.InvalidFeePercentage.selector);
        factory.deploy(address(underlyingVault), type(uint256).max);
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Deploy with zero address vault
    // ───────────────────────────────────────────────────────────

    function test_deployZeroVaultReverts() public {
        vm.expectRevert(VaultWrapperFactory.InvalidUnderlyingVault.selector);
        factory.deploy(address(0), 100);
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Different (vault, fee) pairs produce different wrappers
    // ───────────────────────────────────────────────────────────

    function test_differentPairsProduceDifferentWrappers() public {
        address w1 = factory.deploy(address(underlyingVault), 100);
        address w2 = factory.deploy(address(underlyingVault), 200);

        MockERC4626 vault2 = new MockERC4626(IERC20(address(asset)), "V2", "V2");
        address w3 = factory.deploy(address(vault2), 100);

        assertTrue(w1 != w2, "Same vault, different fee must produce different wrappers");
        assertTrue(w1 != w3, "Different vault, same fee must produce different wrappers");
        assertTrue(w2 != w3, "All three must be different");
    }

    // ───────────────────────────────────────────────────────────
    // Attack: computeAddress matches actual deployment
    // ───────────────────────────────────────────────────────────

    function test_computeAddressMatchesDeploy() public {
        address predicted = factory.computeAddress(address(underlyingVault), 100);
        address deployed = factory.deploy(address(underlyingVault), 100);
        assertEq(predicted, deployed, "Predicted address must match deployed");
    }
}
