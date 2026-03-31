// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeEarnModule} from "../src/SafeEarnModule.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {MessageHashUtils} from "@openzeppelin/utils/cryptography/MessageHashUtils.sol";

/// Test harness that exposes internal signature verification for isolated testing
contract SafeEarnModuleHarness is SafeEarnModule {
    constructor(
        address r,
        address w,
        address o,
        address f
    ) SafeEarnModule(r, w, o, f) {}

    function exposed_verifySignatureAndReplay(
        bytes32 messageHash,
        bytes calldata signature
    ) external {
        _verifySignatureAndReplay(messageHash, signature);
    }

    function exposed_buildDepositMessageHash(
        address token,
        uint256 amount,
        address vault,
        uint256 feePct,
        address safe,
        uint256 nonce
    ) external view returns (bytes32) {
        return _buildDepositMessageHash(token, amount, vault, feePct, safe, nonce);
    }
}

contract SafeEarnModuleTest is Test {
    SafeEarnModule public module;
    SafeEarnModuleHarness public harness;
    VaultWrapperFactory public factory;

    address constant RELAYER = address(0xBEEF);
    address constant SAFE_ADDR = address(0x5AFE);
    address constant WRAPPED_NATIVE = address(0xE770);

    function setUp() public {
        factory = new VaultWrapperFactory();
        module = new SafeEarnModule(
            RELAYER,
            WRAPPED_NATIVE,
            address(this),
            address(factory)
        );
        harness = new SafeEarnModuleHarness(
            RELAYER,
            WRAPPED_NATIVE,
            address(this),
            address(factory)
        );
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 13: Module onInstall Stores Config
    // **Validates: Requirements 8.1**
    // ---------------------------------------------------------------

    function testFuzz_onInstallStoresConfig(
        bytes32 rootHash,
        address feeCollector
    ) public {
        vm.assume(rootHash != bytes32(0));
        vm.assume(feeCollector != address(0));

        vm.prank(SAFE_ADDR);
        module.onInstall(abi.encode(rootHash, feeCollector));

        (bytes32 storedRoot, address storedCollector) = module.safeConfigs(SAFE_ADDR);
        assertEq(storedRoot, rootHash, "Stored rootHash must match input");
        assertEq(storedCollector, feeCollector, "Stored feeCollector must match input");
        assertTrue(module.isInitialized(SAFE_ADDR), "Safe must be initialized after onInstall");
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 14: Module changeMerkleRoot
    // **Validates: Requirements 8.5**
    // ---------------------------------------------------------------

    function testFuzz_changeMerkleRoot(
        bytes32 initialRoot,
        bytes32 newRoot,
        address feeCollector
    ) public {
        vm.assume(initialRoot != bytes32(0));
        vm.assume(newRoot != bytes32(0));
        vm.assume(feeCollector != address(0));

        // Install module for SAFE_ADDR
        vm.prank(SAFE_ADDR);
        module.onInstall(abi.encode(initialRoot, feeCollector));

        // Change merkle root as SAFE_ADDR
        vm.prank(SAFE_ADDR);
        module.changeMerkleRoot(newRoot);

        (bytes32 storedRoot, address storedCollector) = module.safeConfigs(SAFE_ADDR);
        assertEq(storedRoot, newRoot, "rootHash must be updated to newRoot");
        assertEq(storedCollector, feeCollector, "feeCollector must remain unchanged");
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 15: Module onUninstall Clears Config
    // **Validates: Requirements 8.6**
    // ---------------------------------------------------------------

    function testFuzz_onUninstallClearsConfig(
        bytes32 rootHash,
        address feeCollector
    ) public {
        vm.assume(rootHash != bytes32(0));
        vm.assume(feeCollector != address(0));

        // Install first
        vm.prank(SAFE_ADDR);
        module.onInstall(abi.encode(rootHash, feeCollector));

        // Uninstall
        vm.prank(SAFE_ADDR);
        module.onUninstall();

        (bytes32 storedRoot, address storedCollector) = module.safeConfigs(SAFE_ADDR);
        assertEq(storedRoot, bytes32(0), "rootHash must be cleared after uninstall");
        assertEq(storedCollector, address(0), "feeCollector must be cleared after uninstall");
        assertFalse(module.isInitialized(SAFE_ADDR), "Safe must not be initialized after uninstall");
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 18: Relayer Management
    // **Validates: Requirements 9.8**
    // ---------------------------------------------------------------

    function testFuzz_relayerManagement(address newRelayer) public {
        vm.assume(newRelayer != address(0));
        vm.assume(newRelayer != RELAYER);
        // Exclude the test contract (owner) to avoid CannotRemoveSelf when owner is also the relayer
        vm.assume(newRelayer != address(this));

        // Owner adds newRelayer
        module.addAuthorizedRelayer(newRelayer);
        assertTrue(
            module.authorizedRelayers(newRelayer),
            "newRelayer must be authorized after add"
        );

        // Owner removes newRelayer
        module.removeAuthorizedRelayer(newRelayer);
        assertFalse(
            module.authorizedRelayers(newRelayer),
            "newRelayer must not be authorized after remove"
        );

        // Re-add, then test self-removal revert
        module.addAuthorizedRelayer(newRelayer);

        vm.prank(newRelayer);
        vm.expectRevert(SafeEarnModule.CannotRemoveSelf.selector);
        module.removeAuthorizedRelayer(newRelayer);
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 16: Signature Verification
    // **Validates: Requirements 9.2, 9.3, 9.4**
    // ---------------------------------------------------------------

    function testFuzz_signatureVerification(uint256 privateKey) public {
        // secp256k1 order
        uint256 secp256k1Order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        // Bound to valid secp256k1 private key range
        privateKey = bound(privateKey, 1, secp256k1Order - 1);

        address signer = vm.addr(privateKey);

        // Build a message hash (simulating a deposit message)
        bytes32 messageHash = harness.exposed_buildDepositMessageHash(
            address(0x1111),  // token
            1 ether,          // amount
            address(0x2222),  // vault
            100,              // feePct
            SAFE_ADDR,        // safe
            0                 // nonce
        );

        // Sign the EIP-191 prefixed hash
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        if (signer == RELAYER) {
            // Authorized signer — should succeed
            harness.exposed_verifySignatureAndReplay(messageHash, signature);
        } else {
            // Unauthorized signer — should revert
            vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.NotAuthorized.selector, signer));
            harness.exposed_verifySignatureAndReplay(messageHash, signature);
        }
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 17: Replay Protection
    // **Validates: Requirements 9.5, 9.6**
    // ---------------------------------------------------------------

    function testFuzz_replayProtection(uint256 privateKey, uint256 nonce) public {
        // secp256k1 order
        uint256 secp256k1Order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        // Bound to valid secp256k1 private key range
        privateKey = bound(privateKey, 1, secp256k1Order - 1);

        address signer = vm.addr(privateKey);

        // Authorize this signer so the first call succeeds
        harness.addAuthorizedRelayer(signer);

        // Build a message hash with the fuzzed nonce
        bytes32 messageHash = harness.exposed_buildDepositMessageHash(
            address(0x1111),
            1 ether,
            address(0x2222),
            100,
            SAFE_ADDR,
            nonce
        );

        // Sign the EIP-191 prefixed hash
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First call should succeed
        harness.exposed_verifySignatureAndReplay(messageHash, signature);

        // Second call with the same signature should revert
        vm.expectRevert(SafeEarnModule.SignatureAlreadyUsed.selector);
        harness.exposed_verifySignatureAndReplay(messageHash, signature);
    }
}


/// Minimal mock Safe whose fallback always returns true (1) for execTransactionFromModule calls
contract MockSafe {
    fallback() external payable {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

contract SafeEarnModuleMerkleTest is Test {
    SafeEarnModule public module;
    VaultWrapperFactory public factory;
    MockSafe public mockSafe;

    // Known private key so we can sign valid relayer messages
    uint256 constant RELAYER_PK = 0xBEEF;
    address RELAYER;
    address constant WRAPPED_NATIVE = address(0xE770);

    function setUp() public {
        RELAYER = vm.addr(RELAYER_PK);
        factory = new VaultWrapperFactory();
        module = new SafeEarnModule(
            RELAYER,
            WRAPPED_NATIVE,
            address(this),
            address(factory)
        );
        mockSafe = new MockSafe();
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 19: Merkle Proof Verification
    // **Validates: Requirements 10.2, 10.3, 11.2, 11.3**
    // ---------------------------------------------------------------

    function testFuzz_invalidMerkleProofReverts(uint256 feePct, bytes32 fakeProof) public {
        feePct = bound(feePct, 1, 5000);

        // Use a deterministic vault address for the leaf
        address underlyingVault = address(0xABCD);

        // Single-leaf merkle tree: root = leaf, valid proof is empty []
        bytes32 leaf = keccak256(abi.encodePacked(underlyingVault, feePct));
        bytes32 root = leaf;

        // Install module on the mock safe with this root
        address feeCollector = address(0xFEE);
        vm.prank(address(mockSafe));
        module.onInstall(abi.encode(root, feeCollector));

        // Build a valid deposit message hash and sign it with the relayer key
        address token = address(0x1111);
        uint256 amount = 1 ether;
        uint256 nonce = 0;

        bytes32 messageHash = keccak256(abi.encode(
            "deposit",
            block.chainid,
            token,
            amount,
            underlyingVault,
            feePct,
            address(mockSafe),
            nonce
        ));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Build an INVALID proof — any non-empty proof is wrong for a single-leaf tree
        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = fakeProof;

        // Should revert with InvalidMerkleProof
        vm.expectRevert(SafeEarnModule.InvalidMerkleProof.selector);
        module.autoDeposit(
            token,
            amount,
            underlyingVault,
            feePct,
            address(mockSafe),
            nonce,
            signature,
            invalidProof
        );
    }
}

contract SafeEarnModuleMerkleLeafTest is Test {
    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 22: Merkle Leaf Uniqueness
    // **Validates: Requirements 12.1, 12.3**
    // ---------------------------------------------------------------

    function testFuzz_merkleLeafUniqueness(
        address vault1,
        uint256 fee1,
        address vault2,
        uint256 fee2
    ) public pure {
        // At least one input must differ
        vm.assume(vault1 != vault2 || fee1 != fee2);

        bytes32 leaf1 = keccak256(abi.encodePacked(vault1, fee1));
        bytes32 leaf2 = keccak256(abi.encodePacked(vault2, fee2));

        // abi.encodePacked(address, uint256) is unambiguous since both are fixed-size,
        // so different inputs must produce different leaves (collision resistance of keccak256)
        assertNotEq(leaf1, leaf2, "Different (vault, fee) pairs must produce different leaves");
    }
}
