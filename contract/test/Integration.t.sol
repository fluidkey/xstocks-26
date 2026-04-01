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

/// @notice Minimal Safe mock that actually executes module transactions.
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

contract IntegrationTest is Test {
    MockERC20 public asset;
    MockERC4626 public underlyingVault;
    VaultWrapperFactory public factory;
    SafeEarnModule public module;
    TestSafe public safe;

    uint256 constant RELAYER_PK = 0xBEEF;
    address RELAYER;
    address constant WRAPPED_NATIVE = address(0xE770);
    address constant FEE_COLLECTOR = address(0xFEE);
    uint256 constant FEE_PCT = 100; // 1%

    // Single-leaf merkle tree: root = leaf, proof is empty
    bytes32 merkleRoot;
    bytes32[] emptyProof;

    function setUp() public {
        RELAYER = vm.addr(RELAYER_PK);

        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(IERC20(address(asset)), "Test Vault", "vTT");
        factory = new VaultWrapperFactory();
        module = new SafeEarnModule(RELAYER, WRAPPED_NATIVE, address(this), address(factory));
        safe = new TestSafe();

        // Leaf now includes feeCollector
        merkleRoot = keccak256(abi.encodePacked(address(underlyingVault), FEE_PCT, FEE_COLLECTOR));
        emptyProof = new bytes32[](0);

        // Install module — only rootHash now
        vm.prank(address(safe));
        module.onInstall(abi.encode(merkleRoot));
    }

    /// @dev Sign a deposit message with the relayer key.
    function _signDeposit(
        address token, uint256 amount, address vault,
        uint256 feePct, address fc, address safeAddr, uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            "deposit", block.chainid, token, amount, vault, feePct, fc, safeAddr, nonce
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign a withdraw message with the relayer key.
    function _signWithdraw(
        address token, uint256 shares, address vault,
        uint256 feePct, address fc, address safeAddr, uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            "withdraw", block.chainid, token, shares, vault, feePct, fc, safeAddr, nonce
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Execute a deposit through the module and return the wrapper address.
    function _doDeposit(uint256 amount, uint256 nonce) internal returns (address wrapper) {
        asset.mint(address(safe), amount);

        bytes memory sig = _signDeposit(
            address(asset), amount, address(underlyingVault),
            FEE_PCT, FEE_COLLECTOR, address(safe), nonce
        );

        module.autoDeposit(
            address(asset), amount,
            SafeEarnModule.VaultParams({underlyingVault: address(underlyingVault), feePercentage: FEE_PCT, feeCollector: FEE_COLLECTOR}),
            address(safe), nonce, sig, emptyProof
        );

        wrapper = factory.computeAddress(address(underlyingVault), FEE_PCT, FEE_COLLECTOR);
    }

    // ---------------------------------------------------------------
    // Deposit Flow Correctness
    // ---------------------------------------------------------------

    function testFuzz_depositFlowCorrectness(uint256 amount) public {
        amount = bound(amount, 1e6, 1e24);

        asset.mint(address(safe), amount);

        bytes memory sig = _signDeposit(
            address(asset), amount, address(underlyingVault),
            FEE_PCT, FEE_COLLECTOR, address(safe), 0
        );

        module.autoDeposit(
            address(asset), amount,
            SafeEarnModule.VaultParams({underlyingVault: address(underlyingVault), feePercentage: FEE_PCT, feeCollector: FEE_COLLECTOR}),
            address(safe), 0, sig, emptyProof
        );

        address wrapperAddr = factory.computeAddress(address(underlyingVault), FEE_PCT, FEE_COLLECTOR);
        VaultWrapper wrapper = VaultWrapper(wrapperAddr);

        // Safe must hold wrapper shares
        assertGt(wrapper.balanceOf(address(safe)), 0, "Safe must have wrapper shares");

        // Wrapper must hold underlying vault shares
        assertGt(underlyingVault.balanceOf(wrapperAddr), 0, "Wrapper must hold underlying shares");

        // Fee collector is immutable on the wrapper
        assertEq(wrapper.feeCollector(), FEE_COLLECTOR, "Fee collector must match");
    }

    // ---------------------------------------------------------------
    // Withdrawal Flow Correctness
    // ---------------------------------------------------------------

    function testFuzz_withdrawalFlowCorrectness(uint256 amount) public {
        amount = bound(amount, 1e6, 1e24);

        address wrapperAddr = _doDeposit(amount, 0);
        VaultWrapper wrapper = VaultWrapper(wrapperAddr);

        uint256 shares = wrapper.balanceOf(address(safe));
        assertGt(shares, 0, "Safe must have shares after deposit");

        uint256 assetBalBefore = asset.balanceOf(address(safe));

        bytes memory sig = _signWithdraw(
            address(asset), shares, address(underlyingVault),
            FEE_PCT, FEE_COLLECTOR, address(safe), 1
        );

        module.autoWithdraw(
            address(asset), shares,
            SafeEarnModule.VaultParams({underlyingVault: address(underlyingVault), feePercentage: FEE_PCT, feeCollector: FEE_COLLECTOR}),
            address(safe), 1, sig, emptyProof
        );

        assertEq(wrapper.balanceOf(address(safe)), 0, "Shares must be 0 after full redeem");
        assertGt(asset.balanceOf(address(safe)), assetBalBefore, "Asset balance must increase");
    }

    // ---------------------------------------------------------------
    // Full Deposit → Yield → Fee Collect → Withdraw Flow
    // ---------------------------------------------------------------

    function test_fullDepositFeeCollectWithdrawFlow() public {
        uint256 depositAmount = 100e18;

        // Step 1: Deposit
        address wrapperAddr = _doDeposit(depositAmount, 0);
        VaultWrapper wrapper = VaultWrapper(wrapperAddr);
        assertGt(wrapper.balanceOf(address(safe)), 0, "Must have shares");

        // Step 2: Simulate yield by minting assets to the underlying vault
        uint256 yieldAmount = 10e18;
        asset.mint(address(underlyingVault), yieldAmount);

        // Step 3: Collect fees — 1% of 10e18 yield = 0.1e18
        uint256 feeCollectorBalBefore = asset.balanceOf(FEE_COLLECTOR);
        wrapper.collectFees();
        uint256 feesCollected = asset.balanceOf(FEE_COLLECTOR) - feeCollectorBalBefore;
        assertGt(feesCollected, 0, "Fee collector must receive assets");

        // Step 4: Withdraw all remaining shares
        uint256 remainingShares = wrapper.balanceOf(address(safe));

        bytes memory sig = _signWithdraw(
            address(asset), remainingShares, address(underlyingVault),
            FEE_PCT, FEE_COLLECTOR, address(safe), 1
        );

        module.autoWithdraw(
            address(asset), remainingShares,
            SafeEarnModule.VaultParams({underlyingVault: address(underlyingVault), feePercentage: FEE_PCT, feeCollector: FEE_COLLECTOR}),
            address(safe), 1, sig, emptyProof
        );

        uint256 safeAssetBal = asset.balanceOf(address(safe));

        // Depositor gets principal + yield - fees
        assertApproxEqAbs(
            safeAssetBal + feesCollected,
            depositAmount + yieldAmount,
            2,
            "Depositor return + fees must equal deposit + yield"
        );
    }

    // ---------------------------------------------------------------
    // Event emission tests
    // ---------------------------------------------------------------

    function test_depositEmitsEvent() public {
        uint256 amount = 50e18;
        asset.mint(address(safe), amount);

        bytes memory sig = _signDeposit(
            address(asset), amount, address(underlyingVault),
            FEE_PCT, FEE_COLLECTOR, address(safe), 0
        );

        vm.expectEmit(true, true, true, true);
        emit SafeEarnModule.AutoDepositExecuted(address(safe), address(asset), address(underlyingVault), amount);

        module.autoDeposit(
            address(asset), amount,
            SafeEarnModule.VaultParams({underlyingVault: address(underlyingVault), feePercentage: FEE_PCT, feeCollector: FEE_COLLECTOR}),
            address(safe), 0, sig, emptyProof
        );
    }

    function test_withdrawEmitsEvent() public {
        uint256 amount = 50e18;

        address wrapperAddr = _doDeposit(amount, 0);
        VaultWrapper wrapper = VaultWrapper(wrapperAddr);
        uint256 shares = wrapper.balanceOf(address(safe));
        uint256 expectedAssets = wrapper.convertToAssets(shares);

        bytes memory sig = _signWithdraw(
            address(asset), shares, address(underlyingVault),
            FEE_PCT, FEE_COLLECTOR, address(safe), 1
        );

        vm.expectEmit(true, true, true, true);
        emit SafeEarnModule.AutoWithdrawExecuted(
            address(safe), address(asset), address(underlyingVault), shares, expectedAssets
        );

        module.autoWithdraw(
            address(asset), shares,
            SafeEarnModule.VaultParams({underlyingVault: address(underlyingVault), feePercentage: FEE_PCT, feeCollector: FEE_COLLECTOR}),
            address(safe), 1, sig, emptyProof
        );
    }
}
