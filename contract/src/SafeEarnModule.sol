// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {MerkleProof} from "@openzeppelin/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {VaultWrapperFactory} from "./VaultWrapperFactory.sol";
import {VaultWrapper} from "./VaultWrapper.sol";
import {ISafe} from "./ISafe.sol";

/// @notice Minimal WETH interface for wrapping native ETH.
interface IWETH {
    function deposit() external payable;
}

/// @title SafeEarnModule
/// @notice Safe module that enables relayer-triggered deposits and withdrawals
///         through VaultWrappers on behalf of Gnosis Safe smart accounts.
/// @dev Uses merkle proofs to authorize (vault, feePercentage) pairs per Safe,
///      ECDSA signatures for relayer authentication, and on-chain replay
///      protection via executed message hash tracking.
contract SafeEarnModule is Ownable {

    // ──────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────

    /// @notice Sentinel address representing native ETH in deposit/withdraw calls.
    /// @dev When token == NATIVE_TOKEN the module wraps ETH → WETH before deposit.
    address public constant NATIVE_TOKEN =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ──────────────────────────────────────────────────────────────
    // Immutables
    // ──────────────────────────────────────────────────────────────

    /// @notice Address of the wrapped native token contract (e.g. WETH).
    address public immutable wrappedNative;

    /// @notice Factory used to deploy or look up VaultWrapper instances.
    VaultWrapperFactory public immutable factory;

    // ──────────────────────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────────────────────

    /// @notice Per-Safe configuration stored when the module is installed.
    /// @dev rootHash defines which (vault, feePercentage) pairs the Safe is
    ///      authorized to use. feeCollector is forwarded to VaultWrapper on
    ///      every deposit so fees accrue to the correct address.
    struct SafeConfig {
        /// @notice Merkle root of authorized (underlyingVault, feePercentage) pairs
        bytes32 rootHash;
        /// @notice Address that receives accrued fees from this Safe's deposits
        address feeCollector;
    }

    // ──────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────

    /// @notice Per-Safe configuration mapping (merkle root + fee collector).
    mapping(address => SafeConfig) public safeConfigs;

    /// @notice Tracks which addresses are authorized to sign operations.
    mapping(address => bool) public authorizedRelayers;

    /// @notice Tracks already-executed message hashes to prevent replay attacks.
    mapping(bytes32 => bool) public executedHashes;

    // ──────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────

    /// @notice Thrown when the recovered signer is not an authorized relayer.
    /// @param caller The address that was recovered from the signature.
    error NotAuthorized(address caller);

    /// @notice Thrown when an operation targets a Safe that hasn't installed this module.
    /// @param account The Safe address that is not initialized.
    error ModuleNotInitialized(address account);

    /// @notice Thrown when onInstall is called on a Safe that is already initialized.
    /// @param account The Safe address that is already initialized.
    error ModuleAlreadyInitialized(address account);

    /// @notice Thrown when the provided merkle proof does not verify against the stored root.
    error InvalidMerkleProof();

    /// @notice Thrown when a zero merkle root is provided to onInstall or changeMerkleRoot.
    error InvalidMerkleRoot();

    /// @notice Thrown when a zero-address fee collector is provided to onInstall.
    error InvalidFeeCollector();

    /// @notice Thrown when a signature has already been used (replay attempt).
    error SignatureAlreadyUsed();

    /// @notice Thrown when a relayer attempts to remove themselves.
    error CannotRemoveSelf();

    /// @notice Thrown when autoWithdraw targets a wrapper that hasn't been deployed yet.
    error WrapperNotDeployed();

    /// @notice Thrown when wrapping native ETH to WETH via the Safe fails.
    error NativeWrapFailed();

    /// @notice Thrown when the ERC-20 approval via the Safe fails.
    error ApprovalFailed();

    /// @notice Thrown when the deposit call via the Safe fails.
    error DepositFailed();

    /// @notice Thrown when setting the fee collector on the wrapper via the Safe fails.
    error SetFeeCollectorFailed();

    /// @notice Thrown when the redeem call via the Safe fails.
    error RedeemFailed();

    // ──────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────

    /// @notice Emitted when a Safe installs this module via onInstall.
    /// @param account The Safe address that was initialized.
    event ModuleInitialized(address indexed account);

    /// @notice Emitted when a Safe uninstalls this module via onUninstall.
    /// @param account The Safe address that was uninitialized.
    event ModuleUninitialized(address indexed account);

    /// @notice Emitted when a Safe updates its authorized merkle root.
    /// @param account The Safe address whose root changed.
    /// @param oldRoot  The previous merkle root.
    /// @param newRoot  The new merkle root.
    event MerkleRootChanged(
        address indexed account,
        bytes32 oldRoot,
        bytes32 newRoot
    );

    /// @notice Emitted after a successful autoDeposit execution.
    /// @param safe   The Safe that deposited.
    /// @param token  The token deposited (NATIVE_TOKEN sentinel for ETH).
    /// @param vault  The underlying ERC-4626 vault.
    /// @param amount The amount of assets deposited.
    event AutoDepositExecuted(
        address indexed safe,
        address indexed token,
        address indexed vault,
        uint256 amount
    );

    /// @notice Emitted after a successful autoWithdraw execution.
    /// @param safe   The Safe that withdrew.
    /// @param token  The token withdrawn (NATIVE_TOKEN sentinel for ETH).
    /// @param vault  The underlying ERC-4626 vault.
    /// @param shares The number of wrapper shares redeemed.
    /// @param assets The amount of assets returned to the Safe.
    event AutoWithdrawExecuted(
        address indexed safe,
        address indexed token,
        address indexed vault,
        uint256 shares,
        uint256 assets
    );

    /// @notice Emitted when a new relayer is authorized.
    /// @param relayer The address that was added.
    event AddAuthorizedRelayer(address indexed relayer);

    /// @notice Emitted when a relayer is removed.
    /// @param relayer The address that was removed.
    event RemoveAuthorizedRelayer(address indexed relayer);

    // ──────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────

    /// @notice Deploy the module with an initial relayer, WETH address, owner, and factory.
    /// @param _authorizedRelayer First relayer authorized to sign operations.
    /// @param _wrappedNative     Address of the wrapped native token (e.g. WETH).
    /// @param _owner             Contract owner who can manage relayers.
    /// @param _factory           VaultWrapperFactory used to deploy/lookup wrappers.
    constructor(
        address _authorizedRelayer,
        address _wrappedNative,
        address _owner,
        address _factory
    ) Ownable(_owner) {
        wrappedNative = _wrappedNative;
        factory = VaultWrapperFactory(_factory);
        authorizedRelayers[_authorizedRelayer] = true;
        emit AddAuthorizedRelayer(_authorizedRelayer);
    }

    // ──────────────────────────────────────────────────────────────
    // Relayer Management
    // ──────────────────────────────────────────────────────────────

    /// @notice Add a new authorized relayer.
    /// @dev Callable by the contract owner or any existing authorized relayer.
    /// @param newRelayer Address to authorize.
    function addAuthorizedRelayer(address newRelayer) external {
        if (msg.sender != owner() && !authorizedRelayers[msg.sender]) {
            revert NotAuthorized(msg.sender);
        }
        authorizedRelayers[newRelayer] = true;
        emit AddAuthorizedRelayer(newRelayer);
    }

    /// @notice Remove an authorized relayer.
    /// @dev Callable by the contract owner or any existing authorized relayer.
    ///      A relayer cannot remove themselves to prevent accidental lockout.
    /// @param relayer Address to de-authorize.
    function removeAuthorizedRelayer(address relayer) external {
        if (msg.sender != owner() && !authorizedRelayers[msg.sender]) {
            revert NotAuthorized(msg.sender);
        }
        if (msg.sender == relayer) revert CannotRemoveSelf();
        authorizedRelayers[relayer] = false;
        emit RemoveAuthorizedRelayer(relayer);
    }

    // ──────────────────────────────────────────────────────────────
    // Module Lifecycle
    // ──────────────────────────────────────────────────────────────

    /// @notice Called by a Safe to install this module. Stores the merkle root
    ///         and fee collector for the calling Safe.
    /// @dev Reverts if rootHash is zero, feeCollector is zero, or the Safe is
    ///      already initialized.
    /// @param data ABI-encoded (bytes32 rootHash, address feeCollector).
    function onInstall(bytes calldata data) external {
        (bytes32 rootHash, address feeCollector) = abi.decode(data, (bytes32, address));

        if (rootHash == bytes32(0)) revert InvalidMerkleRoot();
        if (feeCollector == address(0)) revert InvalidFeeCollector();
        if (safeConfigs[msg.sender].rootHash != bytes32(0)) {
            revert ModuleAlreadyInitialized(msg.sender);
        }

        safeConfigs[msg.sender] = SafeConfig(rootHash, feeCollector);
        emit ModuleInitialized(msg.sender);
    }

    /// @notice Called by a Safe to uninstall this module. Clears all stored config.
    function onUninstall() external {
        delete safeConfigs[msg.sender];
        emit ModuleUninitialized(msg.sender);
    }

    /// @notice Update the merkle root for the calling Safe.
    /// @dev Only the Safe itself can call this (msg.sender == Safe address).
    /// @param newRoot The new merkle root. Must not be zero.
    function changeMerkleRoot(bytes32 newRoot) external {
        if (newRoot == bytes32(0)) revert InvalidMerkleRoot();

        bytes32 oldRoot = safeConfigs[msg.sender].rootHash;
        safeConfigs[msg.sender].rootHash = newRoot;
        emit MerkleRootChanged(msg.sender, oldRoot, newRoot);
    }

    /// @notice Check whether a smart account has been initialized with this module.
    /// @param smartAccount The address to check.
    /// @return True if the account has a non-zero rootHash stored.
    function isInitialized(address smartAccount) public view returns (bool) {
        return safeConfigs[smartAccount].rootHash != bytes32(0);
    }

    // ──────────────────────────────────────────────────────────────
    // Signature Verification & Replay Protection (internal)
    // ──────────────────────────────────────────────────────────────

    /// @dev Build the keccak256 message hash for a deposit operation.
    ///      Includes chainId for cross-chain replay protection.
    /// @param token          The asset token address.
    /// @param amount         The deposit amount.
    /// @param underlyingVault The target ERC-4626 vault.
    /// @param feePercentage  The fee tier in basis points.
    /// @param safe           The Safe address performing the deposit.
    /// @param nonce          Unique nonce to prevent replay.
    /// @return The keccak256 hash of the encoded message.
    function _buildDepositMessageHash(
        address token,
        uint256 amount,
        address underlyingVault,
        uint256 feePercentage,
        address safe,
        uint256 nonce
    ) internal view returns (bytes32) {
        // Include "deposit" action tag to prevent cross-action replay
        return keccak256(abi.encode(
            "deposit", block.chainid, token, amount,
            underlyingVault, feePercentage, safe, nonce
        ));
    }

    /// @dev Build the keccak256 message hash for a withdraw operation.
    ///      Includes chainId for cross-chain replay protection.
    /// @param token          The asset token address.
    /// @param shares         The number of wrapper shares to redeem.
    /// @param underlyingVault The target ERC-4626 vault.
    /// @param feePercentage  The fee tier in basis points.
    /// @param safe           The Safe address performing the withdrawal.
    /// @param nonce          Unique nonce to prevent replay.
    /// @return The keccak256 hash of the encoded message.
    function _buildWithdrawMessageHash(
        address token,
        uint256 shares,
        address underlyingVault,
        uint256 feePercentage,
        address safe,
        uint256 nonce
    ) internal view returns (bytes32) {
        // Include "withdraw" action tag to prevent cross-action replay
        return keccak256(abi.encode(
            "withdraw", block.chainid, token, shares,
            underlyingVault, feePercentage, safe, nonce
        ));
    }

    /// @dev Recover the signer from an EIP-191 signed message, verify they are
    ///      an authorized relayer, and mark the hash as used to prevent replay.
    /// @param messageHash The raw keccak256 message hash (before EIP-191 prefix).
    /// @param signature   The 65-byte ECDSA signature (r, s, v).
    function _verifySignatureAndReplay(
        bytes32 messageHash,
        bytes calldata signature
    ) internal {
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address signer = ECDSA.recover(ethSignedHash, signature);

        if (!authorizedRelayers[signer]) revert NotAuthorized(signer);
        if (executedHashes[ethSignedHash]) revert SignatureAlreadyUsed();
        executedHashes[ethSignedHash] = true;
    }

    // ──────────────────────────────────────────────────────────────
    // Internal Helpers for Core Operations
    // ──────────────────────────────────────────────────────────────

    /// @dev Verify signature, check module initialization, and validate the
    ///      merkle proof for the (underlyingVault, feePercentage) pair.
    /// @param messageHash   The raw keccak256 message hash.
    /// @param signature     The 65-byte ECDSA signature.
    /// @param safe           The Safe address to verify against.
    /// @param underlyingVault The ERC-4626 vault in the merkle leaf.
    /// @param feePercentage  The fee tier in the merkle leaf.
    /// @param merkleProof    The merkle proof for the (vault, fee) leaf.
    /// @return feeCollector The Safe's configured fee collector address.
    function _verifyAndAuthorize(
        bytes32 messageHash,
        bytes calldata signature,
        address safe,
        address underlyingVault,
        uint256 feePercentage,
        bytes32[] calldata merkleProof
    ) internal returns (address feeCollector) {
        _verifySignatureAndReplay(messageHash, signature);

        SafeConfig storage config = safeConfigs[safe];
        if (config.rootHash == bytes32(0)) revert ModuleNotInitialized(safe);

        bytes32 leaf = keccak256(abi.encodePacked(underlyingVault, feePercentage));
        if (!MerkleProof.verify(merkleProof, config.rootHash, leaf)) {
            revert InvalidMerkleProof();
        }

        feeCollector = config.feeCollector;
    }

    /// @dev If the token is native ETH, wrap it to WETH via the Safe.
    ///      Otherwise return the token address unchanged.
    /// @param token  The token address (may be NATIVE_TOKEN sentinel).
    /// @param amount The amount of ETH to wrap (ignored if not native).
    /// @param safe   The Safe that executes the WETH.deposit() call.
    /// @return depositToken The actual ERC-20 token to use for the deposit.
    function _wrapNativeIfNeeded(
        address token,
        uint256 amount,
        address safe
    ) internal returns (address depositToken) {
        if (token == NATIVE_TOKEN) {
            depositToken = wrappedNative;
            bytes memory wrapData = abi.encodeWithSelector(IWETH.deposit.selector);
            if (!ISafe(safe).execTransactionFromModule(wrappedNative, amount, wrapData, 0)) {
                revert NativeWrapFailed();
            }
        } else {
            depositToken = token;
        }
    }

    /// @dev Approve the wrapper to spend tokens from the Safe, then execute
    ///      the deposit through the wrapper via execTransactionFromModule.
    /// @param depositToken The ERC-20 token the Safe will approve and deposit.
    /// @param amount       The amount of tokens to deposit.
    /// @param wrapper      The VaultWrapper address to deposit into.
    /// @param safe         The Safe that executes the approve + deposit calls.
    /// @param feeCollector The fee collector passed to VaultWrapper.deposit().
    function _executeDeposit(
        address depositToken,
        uint256 amount,
        address wrapper,
        address safe,
        address feeCollector
    ) internal {
        // Set fee collector on the wrapper if not already assigned to this Safe
        if (VaultWrapper(wrapper).depositorFeeCollector(safe) != feeCollector) {
            bytes memory setFcData = abi.encodeWithSelector(
                VaultWrapper.setFeeCollector.selector, feeCollector
            );
            if (!ISafe(safe).execTransactionFromModule(wrapper, 0, setFcData, 0)) {
                revert SetFeeCollectorFailed();
            }
        }

        // Approve the wrapper to pull tokens from the Safe
        bytes memory approveData = abi.encodeWithSelector(
            IERC20.approve.selector, wrapper, amount
        );
        if (!ISafe(safe).execTransactionFromModule(depositToken, 0, approveData, 0)) {
            revert ApprovalFailed();
        }

        // Execute deposit through the wrapper via the Safe (standard ERC-4626)
        bytes memory depositData = abi.encodeWithSelector(
            VaultWrapper.deposit.selector, amount, safe
        );
        if (!ISafe(safe).execTransactionFromModule(wrapper, 0, depositData, 0)) {
            revert DepositFailed();
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Core Operations
    // ──────────────────────────────────────────────────────────────

    /// @notice Execute a relayer-signed deposit into a VaultWrapper on behalf of a Safe.
    /// @dev Verifies the ECDSA signature, validates the merkle proof, deploys the
    ///      wrapper if needed, then orchestrates approve + deposit via the Safe.
    ///      Anyone can submit the transaction — only the signature must come from
    ///      an authorized relayer.
    /// @param token          The asset token to deposit (use NATIVE_TOKEN for ETH).
    /// @param amount         Amount of assets to deposit.
    /// @param underlyingVault The target ERC-4626 vault.
    /// @param feePercentage  Fee tier in basis points (1–5000).
    /// @param safe           The Safe smart account to deposit from.
    /// @param nonce          Unique nonce for replay protection.
    /// @param signature      EIP-191 ECDSA signature from an authorized relayer.
    /// @param merkleProof    Proof that (underlyingVault, feePercentage) is authorized.
    function autoDeposit(
        address token,
        uint256 amount,
        address underlyingVault,
        uint256 feePercentage,
        address safe,
        uint256 nonce,
        bytes calldata signature,
        bytes32[] calldata merkleProof
    ) external {
        bytes32 messageHash = _buildDepositMessageHash(
            token, amount, underlyingVault, feePercentage, safe, nonce
        );
        address feeCollector = _verifyAndAuthorize(
            messageHash, signature, safe, underlyingVault, feePercentage, merkleProof
        );

        address wrapper = factory.deploy(underlyingVault, feePercentage);
        address depositToken = _wrapNativeIfNeeded(token, amount, safe);
        _executeDeposit(depositToken, amount, wrapper, safe, feeCollector);

        emit AutoDepositExecuted(safe, token, underlyingVault, amount);
    }

    /// @notice Execute a relayer-signed withdrawal from a VaultWrapper on behalf of a Safe.
    /// @dev Verifies the ECDSA signature, validates the merkle proof, and redeems
    ///      wrapper shares back to the Safe. For native ETH vaults the Safe receives
    ///      WETH — the owner can unwrap it independently if needed.
    /// @param token          The asset token (use NATIVE_TOKEN for ETH).
    /// @param shares         Number of wrapper shares to redeem.
    /// @param underlyingVault The target ERC-4626 vault.
    /// @param feePercentage  Fee tier in basis points (1–5000).
    /// @param safe           The Safe smart account to withdraw to.
    /// @param nonce          Unique nonce for replay protection.
    /// @param signature      EIP-191 ECDSA signature from an authorized relayer.
    /// @param merkleProof    Proof that (underlyingVault, feePercentage) is authorized.
    function autoWithdraw(
        address token,
        uint256 shares,
        address underlyingVault,
        uint256 feePercentage,
        address safe,
        uint256 nonce,
        bytes calldata signature,
        bytes32[] calldata merkleProof
    ) external {
        bytes32 messageHash = _buildWithdrawMessageHash(
            token, shares, underlyingVault, feePercentage, safe, nonce
        );
        _verifyAndAuthorize(
            messageHash, signature, safe, underlyingVault, feePercentage, merkleProof
        );

        // Compute wrapper address — revert if it hasn't been deployed yet
        address wrapper = factory.computeAddress(underlyingVault, feePercentage);
        if (wrapper.code.length == 0) revert WrapperNotDeployed();

        // Snapshot expected assets before redeem for the event
        uint256 assets = VaultWrapper(wrapper).convertToAssets(shares);

        // Redeem shares via the Safe — assets go back to the Safe
        bytes memory redeemData = abi.encodeWithSelector(
            VaultWrapper.redeem.selector, shares, safe, safe
        );
        if (!ISafe(safe).execTransactionFromModule(wrapper, 0, redeemData, 0)) {
            revert RedeemFailed();
        }

        emit AutoWithdrawExecuted(safe, token, underlyingVault, shares, assets);
    }
}
