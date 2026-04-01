// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title VaultWrapper
/// @notice Non-transferable ERC-4626 wrapper around an underlying ERC-4626 vault.
///         Charges a percentage fee on yield by minting new wrapper shares to an
///         immutable fee collector address, diluting existing holders proportionally.
///
/// @dev Fee mechanism overview:
///
///      1. `lastTotalAssets` is a checkpoint of the wrapper's total asset value at
///         the last state-changing operation. Any growth of `totalAssets()` beyond
///         this checkpoint is considered yield.
///
///      2. `pendingFeeShares()` computes — in real-time — how many shares the fee
///         collector would receive for yield accrued since the last checkpoint.
///         This is a pure view function; it never writes state.
///
///      3. `totalSupply()` is overridden to include `accruedFeeShares` (snapshotted
///         but not yet minted) plus `pendingFeeShares()` (live). This ensures that
///         `convertToAssets()` and `convertToShares()` always reflect the post-fee
///         share price smoothly — users never see sudden value drops.
///
///      4. `collectFees()` is a standalone permissionless function that mints all
///         accrued + pending fee shares to the fee collector in one transaction.
///         Deposits and withdrawals do NOT call it — they only snapshot pending
///         fees into `accruedFeeShares` and bump the checkpoint.
///
///      5. On every deposit/withdraw/redeem/mint, two checkpoint updates happen:
///         - BEFORE share math: snapshot pending fees and set `lastTotalAssets` to
///           current value. This zeroes out `pendingFeeShares()` so the share
///           conversion math doesn't double-count fees already in `accruedFeeShares`.
///         - AFTER the underlying vault interaction: set `lastTotalAssets` again to
///           the new value (which now includes the deposited/withdrawn amount) so
///           the new money isn't mistaken for yield on the next fee calculation.
contract VaultWrapper is ERC20 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────

    /// @notice Thrown when transfer/transferFrom is called — shares are non-transferable.
    error TransfersDisabled();

    /// @notice Thrown when approve is called — approvals disabled for non-transferable shares.
    error ApprovalsDisabled();

    /// @notice Thrown when a deposit or withdrawal specifies zero assets.
    error ZeroAssets();

    /// @notice Thrown when a mint or redeem specifies zero shares.
    error ZeroShares();

    /// @notice Thrown when a redeem or withdraw exceeds the owner's share balance.
    error InsufficientBalance();

    /// @notice Thrown when msg.sender is not the share owner on redeem/withdraw.
    error NotShareOwner();

    // ──────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────

    /// @notice Emitted when fee shares are minted to the fee collector.
    /// @param feeCollector Address that received the minted shares.
    /// @param feeShares    Number of wrapper shares minted as fees.
    event FeesCollected(address indexed feeCollector, uint256 feeShares);

    // ──────────────────────────────────────────────────────────────
    // Immutables
    // ──────────────────────────────────────────────────────────────

    /// @notice The underlying ERC-4626 vault this wrapper deposits into.
    IERC4626 public immutable underlying;

    /// @notice The asset token (same as underlying.asset()).
    IERC20 public immutable asset;

    /// @notice Fee in basis points applied to yield (e.g. 100 = 1%, max 5000 = 50%).
    uint256 public immutable feePercentage;

    /// @notice Address that receives fee shares — set once at deploy, never changes.
    address public immutable feeCollector;

    // ──────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────

    /// @notice Checkpoint of totalAssets() at the last state-changing operation.
    ///         Growth beyond this value is treated as yield subject to fees.
    uint256 public lastTotalAssets;

    /// @notice Fee shares that have been snapshotted from pending calculations
    ///         but not yet minted to the fee collector. Accumulated across
    ///         deposit/withdraw calls and minted in bulk via collectFees().
    uint256 public accruedFeeShares;

    /// @dev Virtual offset added to supply in share conversion math to prevent
    ///      the ERC-4626 inflation/donation attack. Set to 10^decimals so an
    ///      attacker must donate at least that much to steal 1 wei from a victim.
    uint256 private _virtualShareOffset;

    // ──────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────

    /// @notice Deploy a new wrapper for the given underlying vault, fee tier, and collector.
    /// @param _underlying     Address of the underlying ERC-4626 vault.
    /// @param _feePercentage  Fee in basis points applied to yield (1–5000).
    /// @param _feeCollector   Address that receives fee shares.
    constructor(
        address _underlying,
        uint256 _feePercentage,
        address _feeCollector
    ) ERC20("VaultWrapper", "vWRP") {
        underlying = IERC4626(_underlying);
        asset = IERC20(IERC4626(_underlying).asset());
        feePercentage = _feePercentage;
        feeCollector = _feeCollector;

        // Offset scales with wrapper decimals (min 18) for strong inflation protection.
        // For USDC (6 decimals): offset = 1e18, not 1e6.
        uint8 assetDecimals = IERC20Metadata(IERC4626(_underlying).asset()).decimals();
        uint8 wrapperDecimals = assetDecimals > 18 ? assetDecimals : 18;
        _virtualShareOffset = 10 ** uint256(wrapperDecimals);
    }

    // ──────────────────────────────────────────────────────────────
    // Non-transferable overrides
    // ──────────────────────────────────────────────────────────────

    /// @notice Always reverts — wrapper shares are non-transferable.
    function transfer(address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }

    /// @notice Always reverts — wrapper shares are non-transferable.
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }

    /// @notice Always reverts — approvals disabled for non-transferable shares.
    function approve(address, uint256) public pure override returns (bool) {
        revert ApprovalsDisabled();
    }

    /// @notice Decimals are floored at 18 for precision and inflation protection.
    ///         If the underlying asset has more than 18 decimals, we use that instead.
    function decimals() public view override returns (uint8) {
        uint8 assetDecimals = IERC20Metadata(address(asset)).decimals();
        return assetDecimals > 18 ? assetDecimals : 18;
    }

    // ──────────────────────────────────────────────────────────────
    // Virtual Supply (includes unminted fee shares)
    // ──────────────────────────────────────────────────────────────

    /// @notice Fee shares owed from yield accrued since the last checkpoint.
    ///         Computed in real-time so all view functions reflect fees smoothly.
    /// @dev Uses `super.totalSupply() + accruedFeeShares` as the base supply
    ///      instead of `totalSupply()` to avoid circular dependency — since
    ///      `totalSupply()` itself calls this function.
    /// @return The number of shares that would be minted to feeCollector if
    ///         collectFees() were called right now (for the pending portion only).
    function pendingFeeShares() public view returns (uint256) {
        uint256 current = totalAssets();

        // No yield if assets haven't grown past the checkpoint
        if (current <= lastTotalAssets) return 0;

        uint256 yieldAmount = current - lastTotalAssets;
        uint256 feeAssets = yieldAmount.mulDiv(feePercentage, 10000, Math.Rounding.Floor);
        if (feeAssets == 0) return 0;

        // Base supply = actually minted shares + previously accrued (not yet minted) shares.
        // We intentionally exclude pendingFeeShares from this calculation to break the
        // circular dependency with totalSupply().
        uint256 baseSupply = super.totalSupply() + accruedFeeShares;
        return feeAssets.mulDiv(
            baseSupply + _virtualShareOffset,
            current + 1,
            Math.Rounding.Floor
        );
    }

    /// @notice Effective total supply: minted shares + accrued (snapshotted but
    ///         unminted) fee shares + pending (real-time) fee shares.
    /// @dev This override is the core of the smooth-pricing mechanism. By including
    ///      unminted fee shares, convertToAssets() always returns the post-fee value
    ///      so users never see sudden share-price drops when fees are collected.
    function totalSupply() public view override returns (uint256) {
        return super.totalSupply() + accruedFeeShares + pendingFeeShares();
    }

    /// @notice Minted supply only — excludes all virtual/unminted fee shares.
    ///         Useful for off-chain accounting that needs the on-chain ERC-20 balance.
    function mintedSupply() external view returns (uint256) {
        return super.totalSupply();
    }

    // ──────────────────────────────────────────────────────────────
    // ERC-4626 View Functions
    // ──────────────────────────────────────────────────────────────

    /// @notice Total asset value held in the underlying vault.
    /// @dev Raw gross value — fee deduction happens via supply dilution, not here.
    function totalAssets() public view returns (uint256) {
        uint256 bal = underlying.balanceOf(address(this));
        if (bal == 0) return 0;
        return underlying.convertToAssets(bal);
    }

    /// @notice Convert an asset amount to wrapper shares at the current post-fee rate.
    /// @dev Uses the virtual offset in the numerator to prevent inflation attacks.
    /// @param assets Amount of underlying assets.
    /// @return Number of wrapper shares.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(
            totalSupply() + _virtualShareOffset,
            totalAssets() + 1,
            Math.Rounding.Floor
        );
    }

    /// @notice Convert wrapper shares to assets at the current post-fee rate.
    /// @dev Uses the virtual offset in the denominator to prevent inflation attacks.
    /// @param shares Number of wrapper shares.
    /// @return Amount of underlying assets.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares.mulDiv(
            totalAssets() + 1,
            totalSupply() + _virtualShareOffset,
            Math.Rounding.Floor
        );
    }

    /// @notice Preview the number of shares minted for a given deposit.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Preview the assets required to mint a given number of shares.
    /// @dev Rounds up so the caller always pays enough for the requested shares.
    function previewMint(uint256 shares) external view returns (uint256) {
        return shares.mulDiv(
            totalAssets() + 1,
            totalSupply() + _virtualShareOffset,
            Math.Rounding.Ceil
        );
    }

    /// @notice Preview the shares burned to withdraw exact assets.
    /// @dev Rounds up so the owner always burns enough for the requested assets.
    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return assets.mulDiv(
            totalSupply() + _virtualShareOffset,
            totalAssets() + 1,
            Math.Rounding.Ceil
        );
    }

    /// @notice Preview the assets returned for redeeming shares.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @notice Maximum assets that can be deposited (no cap enforced by wrapper).
    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum shares that can be minted (no cap enforced by wrapper).
    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum assets the owner can withdraw.
    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /// @notice Maximum shares the owner can redeem.
    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    // ──────────────────────────────────────────────────────────────
    // Fee Collection
    // ──────────────────────────────────────────────────────────────

    /// @notice Mint all accrued + pending fee shares to the fee collector.
    /// @dev Permissionless — anyone can call. Shares always go to feeCollector.
    ///      Resets accruedFeeShares to zero and bumps the checkpoint so future
    ///      yield measurement starts fresh from the current totalAssets().
    function collectFees() external {
        uint256 pending = pendingFeeShares();
        uint256 toMint = accruedFeeShares + pending;

        // Reset accrued and bump checkpoint regardless of whether we mint,
        // so the next pendingFeeShares() calculation starts clean
        accruedFeeShares = 0;
        lastTotalAssets = totalAssets();

        if (toMint == 0) return;

        _mint(feeCollector, toMint);
        emit FeesCollected(feeCollector, toMint);
    }

    // ──────────────────────────────────────────────────────────────
    // Internal: Fee Snapshot
    // ──────────────────────────────────────────────────────────────

    /// @dev Snapshot pending fee shares into accruedFeeShares and reset the
    ///      checkpoint. Must be called at the start of every mutative function
    ///      BEFORE any share conversion math.
    ///
    ///      Two things happen here:
    ///      1. `accruedFeeShares += pendingFeeShares()` — captures fees owed from
    ///         yield since the last checkpoint so they aren't lost when we move
    ///         the checkpoint forward.
    ///      2. `lastTotalAssets = totalAssets()` — resets the checkpoint so that
    ///         `pendingFeeShares()` returns 0 for the remainder of this call.
    ///         Without this, totalSupply() would double-count: the fees would
    ///         appear in both `accruedFeeShares` AND `pendingFeeShares()`.
    function _snapshotFees() internal {
        accruedFeeShares += pendingFeeShares();
        lastTotalAssets = totalAssets();
    }

    // ──────────────────────────────────────────────────────────────
    // ERC-4626 Mutative Functions
    // ──────────────────────────────────────────────────────────────

    /// @notice Deposit assets and receive wrapper shares.
    /// @param assets   Amount of underlying assets to deposit.
    /// @param receiver Address that receives the minted wrapper shares.
    /// @return shares  Number of wrapper shares minted.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        _snapshotFees();

        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        SafeERC20.forceApprove(asset, address(underlying), assets);
        underlying.deposit(assets, address(this));

        _mint(receiver, shares);

        // Second checkpoint bump: totalAssets() now includes the new deposit.
        // Without this, the deposited amount would be seen as "yield" on the
        // next pendingFeeShares() call and incorrectly charged a fee.
        lastTotalAssets = totalAssets();
    }

    /// @notice Mint exact wrapper shares by depositing the required assets.
    /// @param shares   Number of wrapper shares to mint.
    /// @param receiver Address that receives the minted shares.
    /// @return assets  Amount of underlying assets pulled from the caller.
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        _snapshotFees();

        // Round up so the caller pays enough assets for the requested shares
        assets = shares.mulDiv(
            totalAssets() + 1,
            totalSupply() + _virtualShareOffset,
            Math.Rounding.Ceil
        );
        if (assets == 0) revert ZeroAssets();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        SafeERC20.forceApprove(asset, address(underlying), assets);
        underlying.deposit(assets, address(this));

        _mint(receiver, shares);

        // Bump checkpoint so new assets aren't counted as yield
        lastTotalAssets = totalAssets();
    }

    /// @notice Redeem wrapper shares for underlying assets.
    /// @param shares   Number of wrapper shares to redeem.
    /// @param receiver Address that receives the withdrawn assets.
    /// @param owner    Address whose shares are being redeemed (must be msg.sender).
    /// @return assets  Amount of underlying assets returned.
    function redeem(
        uint256 shares, address receiver, address owner
    ) external returns (uint256 assets) {
        if (msg.sender != owner) revert NotShareOwner();
        if (shares == 0) revert ZeroShares();
        if (balanceOf(owner) < shares) revert InsufficientBalance();
        _snapshotFees();

        assets = convertToAssets(shares);
        if (assets == 0) revert ZeroAssets();

        _burn(owner, shares);
        underlying.withdraw(assets, receiver, address(this));

        // Bump checkpoint so the withdrawn amount isn't seen as negative yield
        lastTotalAssets = totalAssets();
    }

    /// @notice Withdraw exact assets by burning the required wrapper shares.
    /// @param assets   Amount of underlying assets to withdraw.
    /// @param receiver Address that receives the withdrawn assets.
    /// @param owner    Address whose shares are being burned (must be msg.sender).
    /// @return shares  Number of wrapper shares burned.
    function withdraw(
        uint256 assets, address receiver, address owner
    ) external returns (uint256 shares) {
        if (msg.sender != owner) revert NotShareOwner();
        if (assets == 0) revert ZeroAssets();
        _snapshotFees();

        // Round up so the owner burns enough shares for the exact asset withdrawal
        shares = assets.mulDiv(
            totalSupply() + _virtualShareOffset,
            totalAssets() + 1,
            Math.Rounding.Ceil
        );
        if (shares == 0) revert ZeroShares();
        if (balanceOf(owner) < shares) revert InsufficientBalance();

        _burn(owner, shares);
        underlying.withdraw(assets, receiver, address(this));

        // Bump checkpoint so the withdrawn amount isn't seen as negative yield
        lastTotalAssets = totalAssets();
    }
}
