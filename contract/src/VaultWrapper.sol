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
///         Charges an annualized percentage fee on total assets under management
///         by minting new wrapper shares to an immutable fee collector address,
///         diluting existing holders proportionally over time.
///
/// @dev Fee mechanism overview:
///
///      1. `lastFeeTimestamp` records when fees were last snapshotted. Any time
///         elapsed since then accrues fees on the current `totalAssets()`.
///
///      2. `pendingFeeShares()` computes — in real-time — how many shares the fee
///         collector would receive for the time-weighted fee accrued since the
///         last snapshot. This is a pure view function; it never writes state.
///
///      3. `totalSupply()` is overridden to include `accruedFeeShares` (snapshotted
///         but not yet minted) plus `pendingFeeShares()` (live). This ensures that
///         `convertToAssets()` and `convertToShares()` always reflect the post-fee
///         share price smoothly — users never see sudden value drops.
///
///      4. `collectFees()` is a standalone permissionless function that mints all
///         accrued + pending fee shares to the fee collector in one transaction.
///         Deposits and withdrawals do NOT call it — they only snapshot pending
///         fees into `accruedFeeShares` and bump the timestamp.
///
///      5. On every deposit/withdraw/redeem/mint, `_snapshotFees()` is called
///         BEFORE share math: it captures pending fees into `accruedFeeShares`
///         and resets `lastFeeTimestamp` to `block.timestamp` so the conversion
///         math doesn't double-count fees.
///
///      Gas optimization: mutative functions cache `totalAssets()` in transient
///      storage (EIP-1153, Cancun) via `_snapshotFees()`. Subsequent calls to
///      `totalAssets()` within the same transaction return the cached value,
///      avoiding redundant external calls to the underlying vault. The cache
///      auto-clears at the end of the transaction.
contract VaultWrapper is ERC20 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────

    /// @notice Seconds in a 365-day year, used to prorate the annualized fee.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @dev Transient storage slot for caching totalAssets() during mutative calls.
    ///      Stores `totalAssets + 1` so that 0 means "not cached" (since a cached
    ///      value of 0 assets would be stored as 1). Auto-clears at end of tx.
    ///      Slot chosen as keccak256("VaultWrapper.cachedTotalAssets") to avoid collisions.
    bytes32 private constant _CACHED_TOTAL_ASSETS_SLOT =
        0x02d1d826be667104648b9dd907405290c974559794727bef8517394599f5e50d;

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

    /// @notice Annualized fee in basis points applied to total assets (e.g. 100 = 1%, max 5000 = 50%).
    uint256 public immutable feePercentage;

    /// @notice Address that receives fee shares — set once at deploy, never changes.
    address public immutable feeCollector;

    // ──────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────

    /// @notice Timestamp of the last fee snapshot. Time elapsed since this value
    ///         determines how much of the annualized fee has accrued.
    uint256 public lastFeeTimestamp;

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
    /// @param _feePercentage  Annualized fee in basis points applied to total assets (1–5000).
    /// @param _feeCollector   Address that receives fee shares.
    constructor(
        address _underlying,
        uint256 _feePercentage,
        address _feeCollector
    ) ERC20(
        string.concat("Wrapped ", IERC4626(_underlying).name()),
        string.concat("w", IERC4626(_underlying).symbol())
    ) {
        underlying = IERC4626(_underlying);
        asset = IERC20(IERC4626(_underlying).asset());
        feePercentage = _feePercentage;
        feeCollector = _feeCollector;

        // Start the fee clock at deployment
        lastFeeTimestamp = block.timestamp;

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

    /// @notice Fee shares owed from the annualized fee on total assets, prorated
    ///         by the time elapsed since the last snapshot.
    /// @dev Uses `super.totalSupply() + accruedFeeShares` as the base supply
    ///      instead of `totalSupply()` to avoid circular dependency — since
    ///      `totalSupply()` itself calls this function.
    /// @return The number of shares that would be minted to feeCollector if
    ///         collectFees() were called right now (for the pending portion only).
    function pendingFeeShares() public view returns (uint256) {
        uint256 current = totalAssets();
        if (current == 0) return 0;

        uint256 elapsed = block.timestamp - lastFeeTimestamp;
        if (elapsed == 0) return 0;

        // Prorate the annualized fee: feeAssets = totalAssets * feePercentage / 10000 * elapsed / SECONDS_PER_YEAR
        uint256 feeAssets = current.mulDiv(
            feePercentage * elapsed,
            10000 * SECONDS_PER_YEAR,
            Math.Rounding.Floor
        );
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
    /// @dev During mutative calls, returns a cached value from transient storage
    ///      to avoid redundant external calls. View calls always hit the vault.
    function totalAssets() public view returns (uint256) {
        // Check transient cache first — avoids repeated external calls within a tx
        uint256 cached;
        bytes32 slot = _CACHED_TOTAL_ASSETS_SLOT;
        assembly { cached := tload(slot) }
        if (cached != 0) return cached - 1;

        return _fetchTotalAssets();
    }

    /// @dev Fetches totalAssets from the underlying vault (2 external calls).
    ///      Separated so _snapshotFees can call it directly and cache the result.
    function _fetchTotalAssets() internal view returns (uint256) {
        uint256 bal = underlying.balanceOf(address(this));
        if (bal == 0) return 0;
        return underlying.convertToAssets(bal);
    }

    /// @dev Write a totalAssets value into transient storage cache.
    ///      Stores value + 1 so that 0 means "not cached".
    function _cacheTotalAssets(uint256 value) internal {
        bytes32 slot = _CACHED_TOTAL_ASSETS_SLOT;
        assembly { tstore(slot, add(value, 1)) }
    }

    /// @dev Clear the transient storage cache.
    function _clearCache() internal {
        bytes32 slot = _CACHED_TOTAL_ASSETS_SLOT;
        assembly { tstore(slot, 0) }
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
    ///      Resets accruedFeeShares to zero and bumps the timestamp so future
    ///      fee accrual starts fresh from now.
    function collectFees() external {
        // Cache totalAssets for the duration of this call
        _cacheTotalAssets(_fetchTotalAssets());

        uint256 pending = pendingFeeShares();
        uint256 toMint = accruedFeeShares + pending;

        // Reset accrued and bump timestamp regardless of whether we mint,
        // so the next pendingFeeShares() calculation starts clean
        accruedFeeShares = 0;
        lastFeeTimestamp = block.timestamp;

        // Clear cache before any external interaction
        _clearCache();

        if (toMint == 0) return;

        _mint(feeCollector, toMint);
        emit FeesCollected(feeCollector, toMint);
    }

    // ──────────────────────────────────────────────────────────────
    // Internal: Fee Snapshot
    // ──────────────────────────────────────────────────────────────

    /// @dev Snapshot pending fee shares into accruedFeeShares and reset the
    ///      timestamp. Must be called at the start of every mutative function
    ///      BEFORE any share conversion math.
    ///
    ///      Three things happen here:
    ///      1. Fetch totalAssets once and cache it in transient storage so all
    ///         subsequent calls to totalAssets() within this tx are free.
    ///      2. `accruedFeeShares += pendingFeeShares()` — captures time-weighted
    ///         fees owed since the last snapshot so they aren't lost when we
    ///         reset the timestamp.
    ///      3. `lastFeeTimestamp = block.timestamp` — resets the clock so that
    ///         `pendingFeeShares()` returns 0 for the remainder of this call.
    ///         Without this, totalSupply() would double-count: the fees would
    ///         appear in both `accruedFeeShares` AND `pendingFeeShares()`.
    function _snapshotFees() internal {
        // Fetch once from the underlying vault and cache for the rest of the tx
        uint256 currentAssets = _fetchTotalAssets();
        _cacheTotalAssets(currentAssets);

        accruedFeeShares += pendingFeeShares();
        lastFeeTimestamp = block.timestamp;
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

        // Clear cache before external interactions that change totalAssets
        _clearCache();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        SafeERC20.forceApprove(asset, address(underlying), assets);
        underlying.deposit(assets, address(this));

        _mint(receiver, shares);
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

        // Clear cache before external interactions that change totalAssets
        _clearCache();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        SafeERC20.forceApprove(asset, address(underlying), assets);
        underlying.deposit(assets, address(this));

        _mint(receiver, shares);
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

        // Clear cache before external interactions that change totalAssets
        _clearCache();

        _burn(owner, shares);
        underlying.withdraw(assets, receiver, address(this));
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

        // Clear cache before external interactions that change totalAssets
        _clearCache();

        _burn(owner, shares);
        underlying.withdraw(assets, receiver, address(this));
    }
}
