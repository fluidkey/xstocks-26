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

/// @notice Minimal Safe mock that executes module transactions.
contract TestSafe is ISafe {
    function execTransactionFromModule(
        address to, uint256 value, bytes memory data, uint8
    ) external override returns (bool success) {
        (success, ) = to.call{value: value}(data);
    }
    receive() external payable {}
}

/// @notice Safe mock that always returns true without executing.
contract AlwaysTrueSafe is ISafe {
    function execTransactionFromModule(
        address, uint256, bytes memory, uint8
    ) external pure override returns (bool) { return true; }
}

/// @notice Safe mock that always returns false.
contract AlwaysFalseSafe is ISafe {
    function execTransactionFromModule(
        address, uint256, bytes memory, uint8
    ) external pure override returns (bool) { return false; }
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
        // 100 bps (1%) fee on yield, single fee collector
        wrapper = VaultWrapper(factory.deploy(address(underlyingVault), 100, FEE_COLLECTOR));
    }

    // ───────────────────────────────────────────────────────────
    // Attack: Non-owner cannot redeem/withdraw someone else's shares
    // ───────────────────────────────────────────────────────────

    function test_attackerCannotRedeemOthersShares() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        uint256 shares = wrapper.balanceOf(DEPOSITOR);

        vm.prank(ATTACKER);
        vm.expectRevert(VaultWrapper.NotShareOwner.selector);
        wrapper.redeem(shares, ATTACKER, DEPOSITOR);
    }

    function test_attackerCannotWithdrawOthersAssets() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        vm.prank(ATTACKER);
        vm.expectRevert(VaultWrapper.NotShareOwner.selector);
        wrapper.withdraw(50e18, ATTACKER, DEPOSITOR);
    }

    // ───────────────────────────────────────────────────────────
    // Zero amount deposit/withdraw/redeem
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
    // collectFees called repeatedly yields no extra value
    // ───────────────────────────────────────────────────────────

    function test_repeatedCollectFeesNoDoubleExtraction() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        // Simulate yield
        asset.mint(address(underlyingVault), 10e18);

        // First collection — feeCollector receives wrapper shares
        uint256 sharesBefore = wrapper.balanceOf(FEE_COLLECTOR);
        wrapper.collectFees();
        uint256 firstShares = wrapper.balanceOf(FEE_COLLECTOR) - sharesBefore;
        assertGt(firstShares, 0, "First collection should mint fee shares");

        // Immediate second collection — no new yield, should mint nothing
        uint256 sharesBefore2 = wrapper.balanceOf(FEE_COLLECTOR);
        wrapper.collectFees();
        uint256 secondShares = wrapper.balanceOf(FEE_COLLECTOR) - sharesBefore2;
        assertEq(secondShares, 0, "Immediate second collection must mint zero shares");
    }

    // ───────────────────────────────────────────────────────────
    // Redeem more shares than balance
    // ───────────────────────────────────────────────────────────

    function test_redeemMoreThanBalanceReverts() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, DEPOSITOR);

        uint256 shares = wrapper.balanceOf(DEPOSITOR);
        vm.expectRevert(VaultWrapper.InsufficientBalance.selector);
        wrapper.redeem(shares + 1, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();
    }

    // ───────────────────────────────────────────────────────────
    // Depositor cannot extract more than deposited (no yield)
    // ───────────────────────────────────────────────────────────

    function test_depositorCannotExtractMoreThanDeposited() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        uint256 shares = wrapper.deposit(amount, DEPOSITOR);

        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        assertLe(returned, amount, "Cannot extract more than deposited");
    }

    // ───────────────────────────────────────────────────────────
    // Multiple depositors isolation
    // ───────────────────────────────────────────────────────────

    function test_multipleDepositorsIsolation() public {
        address depositor2 = address(0xBEEF);
        uint256 amount = 100e18;

        asset.mint(DEPOSITOR, amount);
        asset.mint(depositor2, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        vm.startPrank(depositor2);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, depositor2);
        vm.stopPrank();

        uint256 shares1 = wrapper.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        uint256 returned1 = wrapper.redeem(shares1, DEPOSITOR, DEPOSITOR);

        uint256 shares2 = wrapper.balanceOf(depositor2);
        vm.prank(depositor2);
        uint256 returned2 = wrapper.redeem(shares2, depositor2, depositor2);

        assertApproxEqAbs(returned1, returned2, 2, "Equal depositors get equal returns");
        assertLe(returned1, amount, "Depositor1 cannot extract more than deposited");
        assertLe(returned2, amount, "Depositor2 cannot extract more than deposited");
    }

    // ───────────────────────────────────────────────────────────
    // Fee collection does not brick withdrawals
    // ───────────────────────────────────────────────────────────

    function test_feeCollectionDoesNotBrickWithdrawals() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        uint256 shares = wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        // Simulate yield and collect fees
        asset.mint(address(underlyingVault), 10e18);
        wrapper.collectFees();

        // Depositor should still be able to redeem
        uint256 remainingShares = wrapper.balanceOf(DEPOSITOR);
        assertEq(remainingShares, shares, "Share balance unchanged after fee collection");

        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(remainingShares, DEPOSITOR, DEPOSITOR);
        assertGt(returned, 0, "Must be able to withdraw after fee collection");
    }

    // ───────────────────────────────────────────────────────────
    // Large AUM does not overflow fee calculation
    // ───────────────────────────────────────────────────────────

    function test_largeAUMDoesNotOverflow() public {
        VaultWrapper highFeeWrapper = VaultWrapper(
            factory.deploy(address(underlyingVault), 5000, FEE_COLLECTOR)
        );

        uint256 largeAmount = 1e30;
        asset.mint(DEPOSITOR, largeAmount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(highFeeWrapper), largeAmount);
        highFeeWrapper.deposit(largeAmount, DEPOSITOR);
        vm.stopPrank();

        // Simulate large yield
        asset.mint(address(underlyingVault), 1e29);

        // Should not revert
        highFeeWrapper.collectFees();
        assertGt(highFeeWrapper.balanceOf(FEE_COLLECTOR), 0, "Fee collector must receive shares");
    }

    // ───────────────────────────────────────────────────────────
    // First depositor inflation attack — mitigated by 1:1 ratio
    // ───────────────────────────────────────────────────────────

    function test_firstDepositorInflationAttack() public {
        // Attacker deposits 1 wei
        asset.mint(ATTACKER, 1);
        vm.startPrank(ATTACKER);
        asset.approve(address(wrapper), 1);
        wrapper.deposit(1, ATTACKER);
        vm.stopPrank();

        // Attacker donates large amount directly to underlying vault
        uint256 donationAmount = 100e18;
        asset.mint(ATTACKER, donationAmount);
        vm.startPrank(ATTACKER);
        asset.approve(address(underlyingVault), donationAmount);
        underlyingVault.deposit(donationAmount, address(wrapper));
        vm.stopPrank();

        // Victim deposits — virtual offset protects them from the inflation attack.
        // The victim gets meaningful shares and retains >99% of deposited value.
        uint256 victimAmount = 50e18;
        asset.mint(DEPOSITOR, victimAmount);
        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), victimAmount);
        uint256 victimShares = wrapper.deposit(victimAmount, DEPOSITOR);
        vm.stopPrank();

        assertGt(victimShares, 0, "Victim must receive shares after inflation attack mitigation");
        uint256 victimAssetValue = wrapper.convertToAssets(victimShares);
        assertGt(victimAssetValue, victimAmount * 99 / 100,
            "Victim must retain >99% of deposited value with virtual offset protection");
    }

    // ───────────────────────────────────────────────────────────
    // Owner can redeem to any receiver
    // ───────────────────────────────────────────────────────────

    function test_ownerCanRedeemToAnyReceiver() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, DEPOSITOR);

        uint256 shares = wrapper.balanceOf(DEPOSITOR);
        address receiver = address(0x9999);
        uint256 returned = wrapper.redeem(shares, receiver, DEPOSITOR);
        vm.stopPrank();

        assertGt(returned, 0, "Redeem succeeded");
        assertGt(asset.balanceOf(receiver), 0, "Receiver got assets");
    }

    // ───────────────────────────────────────────────────────────
    // Mint pulls correct assets
    // ───────────────────────────────────────────────────────────

    function test_mintPullsCorrectAssets() public {
        uint256 amount = 100e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);

        wrapper.deposit(50e18, DEPOSITOR);

        uint256 sharesToMint = 10e18;
        uint256 assetsBefore = asset.balanceOf(DEPOSITOR);
        uint256 assetsPulled = wrapper.mint(sharesToMint, DEPOSITOR);
        uint256 assetsAfter = asset.balanceOf(DEPOSITOR);

        assertEq(assetsBefore - assetsAfter, assetsPulled, "Correct assets pulled for mint");
        vm.stopPrank();
    }

    // ───────────────────────────────────────────────────────────
    // Fee accrual over multiple years
    // ───────────────────────────────────────────────────────────

    function test_feeAccrualOverMultipleYears() public {
        uint256 amount = 1_000_000e18;
        asset.mint(DEPOSITOR, amount);

        vm.startPrank(DEPOSITOR);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, DEPOSITOR);
        vm.stopPrank();

        // Simulate 10% yield
        asset.mint(address(underlyingVault), 100_000e18);

        wrapper.collectFees();
        uint256 feeShares = wrapper.balanceOf(FEE_COLLECTOR);
        assertGt(feeShares, 0, "Fee shares minted");

        // FeeCollector redeems their shares for assets
        vm.prank(FEE_COLLECTOR);
        uint256 feesCollected = wrapper.redeem(feeShares, FEE_COLLECTOR, FEE_COLLECTOR);
        assertGt(feesCollected, 0, "Fee collector got assets");

        uint256 shares = wrapper.balanceOf(DEPOSITOR);
        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        assertGt(returned, 0, "Depositor can withdraw");

        // Total extracted should not exceed total deposited + yield
        assertLe(feesCollected + returned, amount + 100_000e18 + 1,
            "Total extracted must not exceed deposited + yield");
    }

    // ───────────────────────────────────────────────────────────
    // Fee collector is immutable
    // ───────────────────────────────────────────────────────────

    function test_feeCollectorIsImmutable() public view {
        assertEq(wrapper.feeCollector(), FEE_COLLECTOR, "Fee collector set at deploy");
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

        // Leaf includes feeCollector
        merkleRoot = keccak256(abi.encodePacked(address(underlyingVault), FEE_PCT, FEE_COLLECTOR));
        emptyProof = new bytes32[](0);

        vm.prank(address(safe));
        module.onInstall(abi.encode(merkleRoot));
    }

    function _signDeposit(
        uint256 amount, uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), amount,
            address(underlyingVault), FEE_PCT, FEE_COLLECTOR, address(safe), nonce
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signWithdraw(
        uint256 shares, uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            "withdraw", block.chainid, address(asset), shares,
            address(underlyingVault), FEE_PCT, FEE_COLLECTOR, address(safe), nonce
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Default vault params used across all tests in this contract.
    function _vaultParams() internal view returns (SafeEarnModule.VaultParams memory) {
        return SafeEarnModule.VaultParams({
            underlyingVault: address(underlyingVault),
            feePercentage: FEE_PCT,
            feeCollector: FEE_COLLECTOR
        });
    }

    /// @dev Sign an arbitrary message hash with the relayer key.
    function _signHash(bytes32 msgHash) internal view returns (bytes memory) {
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(msgHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign an arbitrary message hash with a given private key.
    function _signHashWith(bytes32 msgHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(msgHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    // ───────────────────────────────────────────────────────────
    // Unauthorized signer cannot execute deposits
    // ───────────────────────────────────────────────────────────

    function test_unauthorizedSignerCannotDeposit() public {
        uint256 attackerPk = 0xDEAD;
        address attacker = vm.addr(attackerPk);

        bytes32 msgHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), uint256(100e18),
            address(underlyingVault), FEE_PCT, FEE_COLLECTOR, address(safe), uint256(0)
        ));

        vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.NotAuthorized.selector, attacker));
        module.autoDeposit(
            address(asset), 100e18,
            _vaultParams(),
            address(safe), 0, _signHashWith(msgHash, attackerPk), emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Replay same signature twice
    // ───────────────────────────────────────────────────────────

    function test_signatureReplayReverts() public {
        uint256 amount = 50e18;
        asset.mint(address(safe), amount * 2);

        bytes memory sig = _signDeposit(amount, 0);

        module.autoDeposit(
            address(asset), amount,
            _vaultParams(),
            address(safe), 0, sig, emptyProof
        );

        vm.expectRevert(SafeEarnModule.SignatureAlreadyUsed.selector);
        module.autoDeposit(
            address(asset), amount,
            _vaultParams(),
            address(safe), 0, sig, emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Uninitialized Safe cannot deposit
    // ───────────────────────────────────────────────────────────

    function test_uninitializedSafeCannotDeposit() public {
        address uninitSafe = address(0x1234);

        bytes32 msgHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), uint256(50e18),
            address(underlyingVault), FEE_PCT, FEE_COLLECTOR, uninitSafe, uint256(0)
        ));

        vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.ModuleNotInitialized.selector, uninitSafe));
        module.autoDeposit(
            address(asset), 50e18,
            _vaultParams(),
            uninitSafe, 0, _signHash(msgHash), emptyProof
        );
    }

    // ───────────────────────────────────────────────────────────
    // Withdraw on non-deployed wrapper reverts
    // ───────────────────────────────────────────────────────────

    function test_withdrawOnNonDeployedWrapperReverts() public {
        address otherVault = address(0x9999);
        bytes32 otherRoot = keccak256(abi.encodePacked(otherVault, FEE_PCT, FEE_COLLECTOR));

        vm.prank(address(safe));
        module.changeMerkleRoot(otherRoot);

        bytes32 msgHash = keccak256(abi.encode(
            "withdraw", block.chainid, address(asset), uint256(100),
            otherVault, FEE_PCT, FEE_COLLECTOR, address(safe), uint256(0)
        ));

        vm.expectRevert(SafeEarnModule.WrapperNotDeployed.selector);
        module.autoWithdraw(
            address(asset), 100,
            SafeEarnModule.VaultParams({
                underlyingVault: otherVault,
                feePercentage: FEE_PCT,
                feeCollector: FEE_COLLECTOR
            }),
            address(safe), 0, _signHash(msgHash), new bytes32[](0)
        );
    }

    // ───────────────────────────────────────────────────────────
    // Double onInstall reverts
    // ───────────────────────────────────────────────────────────

    function test_doubleOnInstallReverts() public {
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.ModuleAlreadyInitialized.selector, address(safe)));
        module.onInstall(abi.encode(merkleRoot));
    }

    // ───────────────────────────────────────────────────────────
    // changeMerkleRoot on uninitialized Safe reverts
    // ───────────────────────────────────────────────────────────

    function test_changeMerkleRootUninitializedReverts() public {
        address uninitSafe = address(0x5555);
        vm.prank(uninitSafe);
        vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.ModuleNotInitialized.selector, uninitSafe));
        module.changeMerkleRoot(bytes32(uint256(1)));
    }

    // ───────────────────────────────────────────────────────────
    // Zero merkle root reverts
    // ───────────────────────────────────────────────────────────

    function test_zeroMerkleRootReverts() public {
        address newSafe = address(0x6666);
        vm.prank(newSafe);
        vm.expectRevert(SafeEarnModule.InvalidMerkleRoot.selector);
        module.onInstall(abi.encode(bytes32(0)));
    }

    // ───────────────────────────────────────────────────────────
    // Failed Safe execution reverts module call
    // ───────────────────────────────────────────────────────────

    function test_failedSafeExecRevertsDeposit() public {
        AlwaysFalseSafe falseSafe = new AlwaysFalseSafe();
        bytes32 root = keccak256(abi.encodePacked(address(underlyingVault), FEE_PCT, FEE_COLLECTOR));

        vm.prank(address(falseSafe));
        module.onInstall(abi.encode(root));

        bytes32 msgHash = keccak256(abi.encode(
            "deposit", block.chainid, address(asset), uint256(50e18),
            address(underlyingVault), FEE_PCT, FEE_COLLECTOR, address(falseSafe), uint256(0)
        ));

        vm.expectRevert(SafeEarnModule.ApprovalFailed.selector);
        module.autoDeposit(
            address(asset), 50e18,
            _vaultParams(),
            address(falseSafe), 0, _signHash(msgHash), new bytes32[](0)
        );
    }
}
