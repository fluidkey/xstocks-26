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

/// A minimal Safe mock that actually executes module transactions
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
    uint256 constant FEE_PCT = 100; // 1% annual

    // Merkle tree: single leaf => root = leaf
    bytes32 merkleRoot;
    bytes32[] emptyProof;

    function setUp() public {
        RELAYER = vm.addr(RELAYER_PK);

        // Deploy core infrastructure
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(IERC20(address(asset)), "Test Vault", "vTT");
        factory = new VaultWrapperFactory();
        module = new SafeEarnModule(RELAYER, WRAPPED_NATIVE, address(this), address(factory));
        safe = new TestSafe();

        // Build single-leaf merkle tree: root = leaf
        merkleRoot = keccak256(abi.encodePacked(address(underlyingVault), FEE_PCT));
        emptyProof = new bytes32[](0);

        // Install module on TestSafe
        vm.prank(address(safe));
        module.onInstall(abi.encode(merkleRoot, FEE_COLLECTOR));
    }

    /// Helper: sign a deposit message with the relayer key
    function _signDeposit(
        address token,
        uint256 amount,
        address vault,
        uint256 feePct,
        address safeAddr,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode("deposit", block.chainid, token, amount, vault, feePct, safeAddr, nonce));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    /// Helper: sign a withdraw message with the relayer key
    function _signWithdraw(
        address token,
        uint256 shares,
        address vault,
        uint256 feePct,
        address safeAddr,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode("withdraw", block.chainid, token, shares, vault, feePct, safeAddr, nonce));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    /// Helper: execute a deposit through the module and return the wrapper address
    function _doDeposit(uint256 amount, uint256 nonce) internal returns (address wrapper) {
        // Fund the Safe with asset tokens
        asset.mint(address(safe), amount);

        bytes memory sig = _signDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT, address(safe), nonce
        );

        module.autoDeposit(
            address(asset),
            amount,
            address(underlyingVault),
            FEE_PCT,
            address(safe),
            nonce,
            sig,
            emptyProof
        );

        wrapper = factory.computeAddress(address(underlyingVault), FEE_PCT);
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 20: Deposit Flow Correctness
    // **Validates: Requirements 10.1, 10.4**
    // ---------------------------------------------------------------

    function testFuzz_depositFlowCorrectness(uint256 amount) public {
        amount = bound(amount, 1e6, 1e24);

        // Fund the Safe with asset tokens
        asset.mint(address(safe), amount);

        bytes memory sig = _signDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT, address(safe), 0
        );

        module.autoDeposit(
            address(asset),
            amount,
            address(underlyingVault),
            FEE_PCT,
            address(safe),
            0,
            sig,
            emptyProof
        );

        address wrapperAddr = factory.computeAddress(address(underlyingVault), FEE_PCT);
        VaultWrapper wrapper = VaultWrapper(wrapperAddr);

        // Safe must hold wrapper shares
        assertGt(wrapper.balanceOf(address(safe)), 0, "Safe must have wrapper shares after deposit");

        // Wrapper must hold underlying vault shares
        assertGt(
            underlyingVault.balanceOf(wrapperAddr),
            0,
            "Wrapper must hold underlying vault shares after deposit"
        );

        // Fee collector assignment must match the Safe's configured feeCollector
        assertEq(
            wrapper.depositorFeeCollector(address(safe)),
            FEE_COLLECTOR,
            "Depositor fee collector must match Safe's configured feeCollector"
        );
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 21: Withdrawal Flow Correctness
    // **Validates: Requirements 11.1, 11.4**
    // ---------------------------------------------------------------

    function testFuzz_withdrawalFlowCorrectness(uint256 amount) public {
        amount = bound(amount, 1e6, 1e24);

        // First deposit
        address wrapperAddr = _doDeposit(amount, 0);
        VaultWrapper wrapper = VaultWrapper(wrapperAddr);

        uint256 shares = wrapper.balanceOf(address(safe));
        assertGt(shares, 0, "Safe must have shares after deposit");

        uint256 assetBalBefore = asset.balanceOf(address(safe));

        // Sign and execute withdrawal for all shares
        bytes memory sig = _signWithdraw(
            address(asset), shares, address(underlyingVault), FEE_PCT, address(safe), 1
        );

        module.autoWithdraw(
            address(asset),
            shares,
            address(underlyingVault),
            FEE_PCT,
            address(safe),
            1,
            sig,
            emptyProof
        );

        // Safe's wrapper share balance should be 0 after full redeem
        assertEq(wrapper.balanceOf(address(safe)), 0, "Safe wrapper shares must be 0 after full redeem");

        // Safe's asset balance must have increased
        assertGt(
            asset.balanceOf(address(safe)),
            assetBalBefore,
            "Safe asset balance must increase after withdrawal"
        );
    }

    // ---------------------------------------------------------------
    // Integration unit tests (Task 13.3)
    // ---------------------------------------------------------------

    function test_fullDepositFeeCollectWithdrawFlow() public {
        uint256 depositAmount = 100e18;

        // Step 1: Deposit
        address wrapperAddr = _doDeposit(depositAmount, 0);
        VaultWrapper wrapper = VaultWrapper(wrapperAddr);

        uint256 sharesAfterDeposit = wrapper.balanceOf(address(safe));
        assertGt(sharesAfterDeposit, 0, "Safe must have shares after deposit");

        // Step 2: Warp time so fees accrue (30 days)
        vm.warp(block.timestamp + 30 days);

        // Step 3: Collect fees
        uint256 feeCollectorBalBefore = asset.balanceOf(FEE_COLLECTOR);
        wrapper.collectFees(FEE_COLLECTOR);
        uint256 feeCollectorBalAfter = asset.balanceOf(FEE_COLLECTOR);

        // Fee collector must have received assets
        assertGt(feeCollectorBalAfter, feeCollectorBalBefore, "Fee collector must receive assets from fee collection");
        uint256 feesCollected = feeCollectorBalAfter - feeCollectorBalBefore;

        // Step 4: Withdraw all remaining shares
        uint256 remainingShares = wrapper.balanceOf(address(safe));

        bytes memory sig = _signWithdraw(
            address(asset), remainingShares, address(underlyingVault), FEE_PCT, address(safe), 1
        );

        module.autoWithdraw(
            address(asset),
            remainingShares,
            address(underlyingVault),
            FEE_PCT,
            address(safe),
            1,
            sig,
            emptyProof
        );

        uint256 safeAssetBal = asset.balanceOf(address(safe));

        // Depositor got back less than deposited because fees were taken
        assertLt(safeAssetBal, depositAmount, "Depositor must get back less than deposited due to fees");

        // The difference should approximately equal the fees collected (within rounding)
        assertApproxEqAbs(
            safeAssetBal + feesCollected,
            depositAmount,
            2,
            "Depositor return + fees must approximately equal original deposit"
        );
    }

    function test_depositEmitsEvent() public {
        uint256 amount = 50e18;
        asset.mint(address(safe), amount);

        bytes memory sig = _signDeposit(
            address(asset), amount, address(underlyingVault), FEE_PCT, address(safe), 0
        );

        vm.expectEmit(true, true, true, true);
        emit SafeEarnModule.AutoDepositExecuted(address(safe), address(asset), address(underlyingVault), amount);

        module.autoDeposit(
            address(asset),
            amount,
            address(underlyingVault),
            FEE_PCT,
            address(safe),
            0,
            sig,
            emptyProof
        );
    }

    function test_withdrawEmitsEvent() public {
        uint256 amount = 50e18;

        // Deposit first
        address wrapperAddr = _doDeposit(amount, 0);
        VaultWrapper wrapper = VaultWrapper(wrapperAddr);
        uint256 shares = wrapper.balanceOf(address(safe));

        bytes memory sig = _signWithdraw(
            address(asset), shares, address(underlyingVault), FEE_PCT, address(safe), 1
        );

        // Compute expected assets for the event
        uint256 expectedAssets = wrapper.convertToAssets(shares);

        vm.expectEmit(true, true, true, true);
        emit SafeEarnModule.AutoWithdrawExecuted(address(safe), address(asset), address(underlyingVault), shares, expectedAssets);

        module.autoWithdraw(
            address(asset),
            shares,
            address(underlyingVault),
            FEE_PCT,
            address(safe),
            1,
            sig,
            emptyProof
        );
    }
}
