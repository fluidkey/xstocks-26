// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeEarnModule} from "../src/SafeEarnModule.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {MessageHashUtils} from "@openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {MockERC20, MockERC4626} from "./mocks/MockERC4626.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

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
        bytes32 root = keccak256(abi.encodePacked(block.chainid, vault, feePct, fc));

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

contract SafeEarnModuleValidMerkleProofTest is Test {
    SafeEarnModule public module;
    VaultWrapperFactory public factory;
    MockSafe public mockSafe;
    MockERC20 public asset;

    uint256 constant RELAYER_PK = 0xBEEF;
    address RELAYER;
    address constant WRAPPED_NATIVE = address(0xE770);

    // 8 real mock ERC-4626 vaults, populated in setUp
    address[8] public vaults;

    address constant FC = address(0xFEE);
    uint256 constant FEE = 100;

    function setUp() public {
        RELAYER = vm.addr(RELAYER_PK);
        factory = new VaultWrapperFactory();
        module = new SafeEarnModule(
            RELAYER, WRAPPED_NATIVE, address(this), address(factory)
        );
        mockSafe = new MockSafe();

        // Deploy a shared underlying asset and 8 distinct vaults
        asset = new MockERC20("Mock", "MCK", 18);
        for (uint256 i = 0; i < 8; i++) {
            vaults[i] = address(
                new MockERC4626(IERC20(address(asset)), "Vault", "vMCK")
            );
        }
    }

    /// @dev OZ MerkleProof uses sorted-pair hashing internally.
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Compute leaf the same way the contract does.
    function _leaf(uint256 idx) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.chainid, vaults[idx], FEE, FC));
    }

    /// @dev Build the full 8-leaf tree and return (root, leaves).
    function _buildTree() internal view returns (bytes32 root, bytes32[8] memory leaves) {
        for (uint256 i = 0; i < 8; i++) {
            leaves[i] = _leaf(i);
        }

        // Layer 1: 4 nodes
        bytes32 n01 = _hashPair(leaves[0], leaves[1]);
        bytes32 n23 = _hashPair(leaves[2], leaves[3]);
        bytes32 n45 = _hashPair(leaves[4], leaves[5]);
        bytes32 n67 = _hashPair(leaves[6], leaves[7]);

        // Layer 2: 2 nodes
        bytes32 n0123 = _hashPair(n01, n23);
        bytes32 n4567 = _hashPair(n45, n67);

        // Root
        root = _hashPair(n0123, n4567);
    }

    /// @dev Build a 3-element proof for leaf at `idx` (0-7) in the 8-leaf tree.
    function _proofFor(uint8 idx, bytes32[8] memory leaves) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](3);

        // Layer 1: 4 nodes
        bytes32 n01 = _hashPair(leaves[0], leaves[1]);
        bytes32 n23 = _hashPair(leaves[2], leaves[3]);
        bytes32 n45 = _hashPair(leaves[4], leaves[5]);
        bytes32 n67 = _hashPair(leaves[6], leaves[7]);

        // Layer 2: 2 nodes
        bytes32 n0123 = _hashPair(n01, n23);
        bytes32 n4567 = _hashPair(n45, n67);

        // Sibling at each layer depends on the leaf index
        if (idx < 4) {
            proof[2] = n4567;
            if (idx < 2) {
                proof[1] = n23;
                proof[0] = leaves[idx ^ 1]; // sibling leaf
            } else {
                proof[1] = n01;
                proof[0] = leaves[idx ^ 1];
            }
        } else {
            proof[2] = n0123;
            if (idx < 6) {
                proof[1] = n67;
                proof[0] = leaves[idx ^ 1];
            } else {
                proof[1] = n45;
                proof[0] = leaves[idx ^ 1];
            }
        }
    }

    function _signMsg(bytes32 messageHash) internal view returns (bytes memory) {
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_PK, ethHash);
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------
    // Valid 8-leaf merkle proof accepted by autoDeposit
    // ---------------------------------------------------------------

    /// @dev Deposits through leaf 0 with a valid 3-step proof.
    function test_validMerkleProof_leaf0() public {
        (bytes32 root, bytes32[8] memory leaves) = _buildTree();
        bytes32[] memory proof = _proofFor(0, leaves);

        vm.prank(address(mockSafe));
        module.onInstall(abi.encode(root));

        SafeEarnModule.VaultParams memory vp = SafeEarnModule.VaultParams({
            underlyingVault: vaults[0], feePercentage: FEE, feeCollector: FC
        });

        bytes memory sig = _signMsg(
            keccak256(abi.encode(
                "deposit", block.chainid, address(0x1111), uint256(1 ether),
                vaults[0], FEE, FC, address(mockSafe), uint256(0)
            ))
        );

        // Should NOT revert — proof is valid
        module.autoDeposit(
            address(0x1111), 1 ether, vp,
            address(mockSafe), 0, sig, proof
        );
    }

    /// @dev Deposits through leaf 5 to test a non-zero index path.
    function test_validMerkleProof_leaf5() public {
        (bytes32 root, bytes32[8] memory leaves) = _buildTree();
        bytes32[] memory proof = _proofFor(5, leaves);

        vm.prank(address(mockSafe));
        module.onInstall(abi.encode(root));

        SafeEarnModule.VaultParams memory vp = SafeEarnModule.VaultParams({
            underlyingVault: vaults[5], feePercentage: FEE, feeCollector: FC
        });

        bytes memory sig = _signMsg(
            keccak256(abi.encode(
                "deposit", block.chainid, address(0x1111), uint256(1 ether),
                vaults[5], FEE, FC, address(mockSafe), uint256(1)
            ))
        );

        module.autoDeposit(
            address(0x1111), 1 ether, vp,
            address(mockSafe), 1, sig, proof
        );
    }

    /// @dev Proves that a valid proof for one leaf fails for a different leaf.
    function test_validProofWrongLeafReverts() public {
        (bytes32 root, bytes32[8] memory leaves) = _buildTree();
        // Get proof for leaf 0 but try to use it with leaf 3's vault
        bytes32[] memory proof = _proofFor(0, leaves);

        vm.prank(address(mockSafe));
        module.onInstall(abi.encode(root));

        SafeEarnModule.VaultParams memory vp = SafeEarnModule.VaultParams({
            underlyingVault: vaults[3], feePercentage: FEE, feeCollector: FC
        });

        bytes memory sig = _signMsg(
            keccak256(abi.encode(
                "deposit", block.chainid, address(0x1111), uint256(1 ether),
                vaults[3], FEE, FC, address(mockSafe), uint256(0)
            ))
        );

        vm.expectRevert(SafeEarnModule.InvalidMerkleProof.selector);
        module.autoDeposit(
            address(0x1111), 1 ether, vp,
            address(mockSafe), 0, sig, proof
        );
    }
}

contract SafeEarnModuleMerkleLeafTest is Test {
    // ---------------------------------------------------------------
    // Merkle Leaf Uniqueness — now includes feeCollector
    // ---------------------------------------------------------------

    function testFuzz_merkleLeafUniqueness(
        address vault1, uint256 fee1, address fc1,
        address vault2, uint256 fee2, address fc2
    ) public view {
        vm.assume(vault1 != vault2 || fee1 != fee2 || fc1 != fc2);

        bytes32 leaf1 = keccak256(abi.encodePacked(block.chainid, vault1, fee1, fc1));
        bytes32 leaf2 = keccak256(abi.encodePacked(block.chainid, vault2, fee2, fc2));

        assertNotEq(leaf1, leaf2, "Different inputs must produce different leaves");
    }
}
