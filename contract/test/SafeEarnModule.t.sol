// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeEarnModule} from "../src/SafeEarnModule.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {MessageHashUtils} from "@openzeppelin/utils/cryptography/MessageHashUtils.sol";

/// @notice Test harness exposing internal helpers for isolated testing.
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
        VaultParams calldata vault,
        address safe,
        uint256 nonce
    ) external view returns (bytes32) {
        return _buildDepositMessageHash(token, amount, vault, safe, nonce);
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
            RELAYER, WRAPPED_NATIVE, address(this), address(factory)
        );
        harness = new SafeEarnModuleHarness(
            RELAYER, WRAPPED_NATIVE, address(this), address(factory)
        );
    }

    // ---------------------------------------------------------------
    // onInstall stores root hash
    // ---------------------------------------------------------------

    function testFuzz_onInstallStoresConfig(bytes32 rootHash) public {
        vm.assume(rootHash != bytes32(0));

        vm.prank(SAFE_ADDR);
        module.onInstall(abi.encode(rootHash));

        assertEq(module.safeRootHashes(SAFE_ADDR), rootHash, "Stored rootHash must match");
        assertTrue(module.isInitialized(SAFE_ADDR), "Safe must be initialized");
    }

    // ---------------------------------------------------------------
    // changeMerkleRoot
    // ---------------------------------------------------------------

    function testFuzz_changeMerkleRoot(bytes32 initialRoot, bytes32 newRoot) public {
        vm.assume(initialRoot != bytes32(0));
        vm.assume(newRoot != bytes32(0));

        vm.prank(SAFE_ADDR);
        module.onInstall(abi.encode(initialRoot));

        vm.prank(SAFE_ADDR);
        module.changeMerkleRoot(newRoot);

        assertEq(module.safeRootHashes(SAFE_ADDR), newRoot, "rootHash must be updated");
    }

    // ---------------------------------------------------------------
    // onUninstall clears config
    // ---------------------------------------------------------------

    function testFuzz_onUninstallClearsConfig(bytes32 rootHash) public {
        vm.assume(rootHash != bytes32(0));

        vm.prank(SAFE_ADDR);
        module.onInstall(abi.encode(rootHash));

        vm.prank(SAFE_ADDR);
        module.onUninstall();

        assertEq(module.safeRootHashes(SAFE_ADDR), bytes32(0), "rootHash must be cleared");
        assertFalse(module.isInitialized(SAFE_ADDR), "Safe must not be initialized");
    }

    // ---------------------------------------------------------------
    // Relayer Management
    // ---------------------------------------------------------------

    function testFuzz_relayerManagement(address newRelayer) public {
        vm.assume(newRelayer != address(0));
        vm.assume(newRelayer != RELAYER);
        vm.assume(newRelayer != address(this));

        module.addAuthorizedRelayer(newRelayer);
        assertTrue(module.authorizedRelayers(newRelayer), "Must be authorized after add");

        module.removeAuthorizedRelayer(newRelayer);
        assertFalse(module.authorizedRelayers(newRelayer), "Must not be authorized after remove");

        // Self-removal revert
        module.addAuthorizedRelayer(newRelayer);
        vm.prank(newRelayer);
        vm.expectRevert(SafeEarnModule.CannotRemoveSelf.selector);
        module.removeAuthorizedRelayer(newRelayer);
    }

    // ---------------------------------------------------------------
    // Signature Verification
    // ---------------------------------------------------------------

    function testFuzz_signatureVerification(uint256 privateKey) public {
        uint256 secp256k1Order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        privateKey = bound(privateKey, 1, secp256k1Order - 1);
        address signer = vm.addr(privateKey);

        SafeEarnModule.VaultParams memory vaultParams = SafeEarnModule.VaultParams({
            underlyingVault: address(0x2222),
            feePercentage: 100,
            feeCollector: address(0xFEE)
        });

        bytes32 messageHash = harness.exposed_buildDepositMessageHash(
            address(0x1111), 1 ether, vaultParams, SAFE_ADDR, 0
        );

        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        if (signer == RELAYER) {
            harness.exposed_verifySignatureAndReplay(messageHash, signature);
        } else {
            vm.expectRevert(abi.encodeWithSelector(SafeEarnModule.NotAuthorized.selector, signer));
            harness.exposed_verifySignatureAndReplay(messageHash, signature);
        }
    }

    // ---------------------------------------------------------------
    // Replay Protection
    // ---------------------------------------------------------------

    function testFuzz_replayProtection(uint256 privateKey, uint256 nonce) public {
        uint256 secp256k1Order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        privateKey = bound(privateKey, 1, secp256k1Order - 1);
        address signer = vm.addr(privateKey);

        harness.addAuthorizedRelayer(signer);

        SafeEarnModule.VaultParams memory vaultParams = SafeEarnModule.VaultParams({
            underlyingVault: address(0x2222),
            feePercentage: 100,
            feeCollector: address(0xFEE)
        });

        bytes32 messageHash = harness.exposed_buildDepositMessageHash(
            address(0x1111), 1 ether, vaultParams, SAFE_ADDR, nonce
        );

        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First call succeeds
        harness.exposed_verifySignatureAndReplay(messageHash, signature);

        // Replay reverts
        vm.expectRevert(SafeEarnModule.SignatureAlreadyUsed.selector);
        harness.exposed_verifySignatureAndReplay(messageHash, signature);
    }
}


/// @notice Minimal mock Safe that always returns true for execTransactionFromModule.
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

    uint256 constant RELAYER_PK = 0xBEEF;
    address RELAYER;
    address constant WRAPPED_NATIVE = address(0xE770);

    function setUp() public {
        RELAYER = vm.addr(RELAYER_PK);
        factory = new VaultWrapperFactory();
        module = new SafeEarnModule(
            RELAYER, WRAPPED_NATIVE, address(this), address(factory)
        );
        mockSafe = new MockSafe();
    }

    // ---------------------------------------------------------------
    // Invalid Merkle Proof Reverts
    // ---------------------------------------------------------------

    function testFuzz_invalidMerkleProofReverts(uint256 feePct, bytes32 fakeProof) public {
        feePct = bound(feePct, 1, 5000);

        // Use fixed addresses to reduce local variable count
        address vault = address(0xABCD);
        address fc = address(0xFEE);

        // Single-leaf tree: root = leaf
        bytes32 root = keccak256(abi.encodePacked(vault, feePct, fc));

        vm.prank(address(mockSafe));
        module.onInstall(abi.encode(root));

        // Sign the deposit message
        bytes memory signature = _signMsg(
            keccak256(abi.encode(
                "deposit", block.chainid, address(0x1111), uint256(1 ether),
                vault, feePct, fc, address(mockSafe), uint256(0)
            ))
        );

        // Any non-empty proof is wrong for a single-leaf tree
        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = fakeProof;

        vm.expectRevert(SafeEarnModule.InvalidMerkleProof.selector);
        module.autoDeposit(
            address(0x1111), 1 ether,
            SafeEarnModule.VaultParams({underlyingVault: vault, feePercentage: feePct, feeCollector: fc}),
            address(mockSafe), 0, signature, invalidProof
        );
    }

    /// @dev Helper to sign a message hash with the relayer key.
    function _signMsg(bytes32 messageHash) internal view returns (bytes memory) {
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethHash);
        return abi.encodePacked(r, s, v);
    }
}

contract SafeEarnModuleMerkleLeafTest is Test {
    // ---------------------------------------------------------------
    // Merkle Leaf Uniqueness — now includes feeCollector
    // ---------------------------------------------------------------

    function testFuzz_merkleLeafUniqueness(
        address vault1, uint256 fee1, address fc1,
        address vault2, uint256 fee2, address fc2
    ) public pure {
        vm.assume(vault1 != vault2 || fee1 != fee2 || fc1 != fc2);

        bytes32 leaf1 = keccak256(abi.encodePacked(vault1, fee1, fc1));
        bytes32 leaf2 = keccak256(abi.encodePacked(vault2, fee2, fc2));

        assertNotEq(leaf1, leaf2, "Different inputs must produce different leaves");
    }
}
