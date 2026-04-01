// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {SafeEarnModule} from "../src/SafeEarnModule.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {VaultWrapper} from "../src/VaultWrapper.sol";
import {ISafe} from "../src/ISafe.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {MessageHashUtils} from "@openzeppelin/utils/cryptography/MessageHashUtils.sol";

/// @notice Mainnet fork test measuring real gas costs for autoDeposit and
///         autoWithdraw through a Morpho vault. Run with:
///
///         forge test --match-contract GasForkTest --fork-url $MAINNET_RPC_URL -vvv
///
/// @dev Uses the Gauntlet USDC Prime Morpho vault on Ethereum mainnet.
///      The test impersonates a real Safe and deals USDC to it.
contract GasForkTest is Test {

    // ── Mainnet addresses ────────────────────────────────────────
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Gauntlet USDC Core — MetaMorpho vault on Ethereum mainnet
    address constant MORPHO_VAULT = 0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458;

    VaultWrapperFactory public factory;
    SafeEarnModule public module;

    uint256 constant RELAYER_PK = 0xBEEF;
    address RELAYER;
    address constant FEE_COLLECTOR = address(0xFEE);
    uint256 constant FEE_PCT = 100; // 1% annualized

    // We deploy a minimal Safe that actually executes calls
    TestSafeForFork public safe;

    bytes32 merkleRoot;
    bytes32[] emptyProof;

    function setUp() public {
        RELAYER = vm.addr(RELAYER_PK);

        // Skip gracefully if not running on a real mainnet fork
        if (MORPHO_VAULT.code.length == 0) {
            vm.skip(true);
        }

        factory = new VaultWrapperFactory();
        module = new SafeEarnModule(RELAYER, WETH, address(this), address(factory));
        safe = new TestSafeForFork();

        merkleRoot = keccak256(abi.encodePacked(
            block.chainid, MORPHO_VAULT, FEE_PCT, FEE_COLLECTOR
        ));
        emptyProof = new bytes32[](0);

        // Install module on the Safe
        vm.prank(address(safe));
        module.onInstall(abi.encode(merkleRoot));

        // Deal 10,000 USDC to the Safe
        deal(USDC, address(safe), 10_000e6);
    }

    function _signDeposit(uint256 amount, uint256 nonce) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            "deposit", block.chainid, USDC, amount,
            MORPHO_VAULT, FEE_PCT, FEE_COLLECTOR, address(safe), nonce
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signWithdraw(uint256 shares, uint256 nonce) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            "withdraw", block.chainid, USDC, shares,
            MORPHO_VAULT, FEE_PCT, FEE_COLLECTOR, address(safe), nonce
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _vaultParams() internal pure returns (SafeEarnModule.VaultParams memory) {
        return SafeEarnModule.VaultParams({
            underlyingVault: MORPHO_VAULT,
            feePercentage: FEE_PCT,
            feeCollector: FEE_COLLECTOR
        });
    }

    // ───────────────────────────────────────────────────────────
    // Gas: First deposit (deploys wrapper via CREATE2)
    // ───────────────────────────────────────────────────────────

    function test_gas_firstDeposit() public {
        uint256 amount = 1_000e6; // 1,000 USDC
        bytes memory sig = _signDeposit(amount, 0);

        uint256 gasBefore = gasleft();
        module.autoDeposit(
            USDC, amount, _vaultParams(),
            address(safe), 0, sig, emptyProof
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== FIRST DEPOSIT (wrapper deploy + deposit) ===");
        console.log("Gas used:", gasUsed);

        // Verify it worked
        address wrapper = factory.computeAddress(MORPHO_VAULT, FEE_PCT, FEE_COLLECTOR);
        assertGt(VaultWrapper(wrapper).balanceOf(address(safe)), 0, "Safe must have wrapper shares");
    }

    // ───────────────────────────────────────────────────────────
    // Gas: Second deposit (wrapper already deployed)
    // ───────────────────────────────────────────────────────────

    function test_gas_secondDeposit() public {
        // First deposit to deploy the wrapper
        uint256 amount = 1_000e6;
        bytes memory sig1 = _signDeposit(amount, 0);
        module.autoDeposit(
            USDC, amount, _vaultParams(),
            address(safe), 0, sig1, emptyProof
        );

        // Second deposit — wrapper already exists, measures steady-state gas
        bytes memory sig2 = _signDeposit(amount, 1);

        uint256 gasBefore = gasleft();
        module.autoDeposit(
            USDC, amount, _vaultParams(),
            address(safe), 1, sig2, emptyProof
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== SECOND DEPOSIT (wrapper exists) ===");
        console.log("Gas used:", gasUsed);
    }

    // ───────────────────────────────────────────────────────────
    // Gas: Withdraw (redeem all shares)
    // ───────────────────────────────────────────────────────────

    function test_gas_withdraw() public {
        // Deposit first
        uint256 amount = 1_000e6;
        bytes memory sig1 = _signDeposit(amount, 0);
        module.autoDeposit(
            USDC, amount, _vaultParams(),
            address(safe), 0, sig1, emptyProof
        );

        address wrapper = factory.computeAddress(MORPHO_VAULT, FEE_PCT, FEE_COLLECTOR);
        uint256 shares = VaultWrapper(wrapper).balanceOf(address(safe));

        bytes memory sig2 = _signWithdraw(shares, 1);

        uint256 gasBefore = gasleft();
        module.autoWithdraw(
            USDC, shares, _vaultParams(),
            address(safe), 1, sig2, emptyProof
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== WITHDRAW (redeem all) ===");
        console.log("Gas used:", gasUsed);

        assertGt(IERC20(USDC).balanceOf(address(safe)), 0, "Safe must have USDC back");
    }

    // ───────────────────────────────────────────────────────────
    // Gas: Deposit after time elapsed (fee snapshot overhead)
    // ───────────────────────────────────────────────────────────

    function test_gas_depositAfterFeeAccrual() public {
        // First deposit
        uint256 amount = 1_000e6;
        bytes memory sig1 = _signDeposit(amount, 0);
        module.autoDeposit(
            USDC, amount, _vaultParams(),
            address(safe), 0, sig1, emptyProof
        );

        // Warp 30 days so fees have accrued
        vm.warp(block.timestamp + 30 days);

        // Second deposit with pending fees to snapshot
        bytes memory sig2 = _signDeposit(amount, 1);

        uint256 gasBefore = gasleft();
        module.autoDeposit(
            USDC, amount, _vaultParams(),
            address(safe), 1, sig2, emptyProof
        );
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== DEPOSIT AFTER 30 DAYS (fee snapshot) ===");
        console.log("Gas used:", gasUsed);
    }

    // ───────────────────────────────────────────────────────────
    // Gas: collectFees standalone
    // ───────────────────────────────────────────────────────────

    function test_gas_collectFees() public {
        // Deposit first
        uint256 amount = 5_000e6;
        bytes memory sig1 = _signDeposit(amount, 0);
        module.autoDeposit(
            USDC, amount, _vaultParams(),
            address(safe), 0, sig1, emptyProof
        );

        // Warp 90 days
        vm.warp(block.timestamp + 90 days);

        address wrapper = factory.computeAddress(MORPHO_VAULT, FEE_PCT, FEE_COLLECTOR);

        uint256 gasBefore = gasleft();
        VaultWrapper(wrapper).collectFees();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== COLLECT FEES (after 90 days) ===");
        console.log("Gas used:", gasUsed);

        assertGt(VaultWrapper(wrapper).balanceOf(FEE_COLLECTOR), 0, "Fee collector must have shares");
    }

    // ───────────────────────────────────────────────────────────
    // Baseline: Raw Morpho vault deposit (no wrapper, no module)
    // ───────────────────────────────────────────────────────────

    function test_gas_baseline_morphoDeposit() public {
        uint256 amount = 1_000e6;

        // Approve the Morpho vault directly from the Safe
        vm.startPrank(address(safe));
        IERC20(USDC).approve(MORPHO_VAULT, amount);

        uint256 gasBefore = gasleft();
        IERC4626(MORPHO_VAULT).deposit(amount, address(safe));
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        console.log("=== BASELINE: Raw Morpho deposit (no wrapper) ===");
        console.log("Gas used:", gasUsed);
    }

    // ───────────────────────────────────────────────────────────
    // Baseline: Raw Morpho vault withdraw (no wrapper, no module)
    // ───────────────────────────────────────────────────────────

    function test_gas_baseline_morphoWithdraw() public {
        uint256 amount = 1_000e6;

        // Deposit directly first
        vm.startPrank(address(safe));
        IERC20(USDC).approve(MORPHO_VAULT, amount);
        uint256 shares = IERC4626(MORPHO_VAULT).deposit(amount, address(safe));

        uint256 gasBefore = gasleft();
        IERC4626(MORPHO_VAULT).redeem(shares, address(safe), address(safe));
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        console.log("=== BASELINE: Raw Morpho redeem (no wrapper) ===");
        console.log("Gas used:", gasUsed);
    }

    // ───────────────────────────────────────────────────────────
    // Baseline: Wrapper-only deposit (no module/signature overhead)
    // ───────────────────────────────────────────────────────────

    function test_gas_baseline_wrapperOnlyDeposit() public {
        // Deploy wrapper first via a throwaway module deposit
        uint256 amount = 1_000e6;
        bytes memory sig1 = _signDeposit(amount, 0);
        module.autoDeposit(
            USDC, amount, _vaultParams(),
            address(safe), 0, sig1, emptyProof
        );

        address wrapper = factory.computeAddress(MORPHO_VAULT, FEE_PCT, FEE_COLLECTOR);

        // Now measure a direct wrapper deposit (bypassing the module)
        deal(USDC, address(this), amount);
        IERC20(USDC).approve(wrapper, amount);

        uint256 gasBefore = gasleft();
        VaultWrapper(wrapper).deposit(amount, address(this));
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== BASELINE: Wrapper-only deposit (no module) ===");
        console.log("Gas used:", gasUsed);
    }

    // ───────────────────────────────────────────────────────────
    // Baseline: Wrapper-only redeem (no module/signature overhead)
    // ───────────────────────────────────────────────────────────

    function test_gas_baseline_wrapperOnlyRedeem() public {
        // Deploy wrapper and deposit via module
        uint256 amount = 1_000e6;
        bytes memory sig1 = _signDeposit(amount, 0);
        module.autoDeposit(
            USDC, amount, _vaultParams(),
            address(safe), 0, sig1, emptyProof
        );

        address wrapper = factory.computeAddress(MORPHO_VAULT, FEE_PCT, FEE_COLLECTOR);

        // Deposit directly to the wrapper from this test contract
        deal(USDC, address(this), amount);
        IERC20(USDC).approve(wrapper, amount);
        uint256 shares = VaultWrapper(wrapper).deposit(amount, address(this));

        uint256 gasBefore = gasleft();
        VaultWrapper(wrapper).redeem(shares, address(this), address(this));
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== BASELINE: Wrapper-only redeem (no module) ===");
        console.log("Gas used:", gasUsed);
    }
}

/// @notice Minimal Safe mock that executes calls — same as in other tests
///         but in its own contract to avoid import conflicts.
contract TestSafeForFork is ISafe {
    function execTransactionFromModule(
        address to, uint256 value, bytes memory data, uint8
    ) external override returns (bool success) {
        (success, ) = to.call{value: value}(data);
    }
    receive() external payable {}
}
