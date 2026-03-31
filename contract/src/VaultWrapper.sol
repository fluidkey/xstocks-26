// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title VaultWrapper
/// @notice Non-transferable ERC-20 share token that wraps an underlying ERC-4626
///         vault, tracks per-depositor positions, and applies a fixed annual
///         percentage fee via virtual share dilution per Fee Collector.
/// @dev Shares are non-transferable — transfer, transferFrom, and approve all
///      revert. Only internal _mint (from zero address) and _burn (to zero
///      address) are allowed for deposit/withdrawal flows.
///
///      The fee mechanism works by computing "virtual" shares that represent the
///      fee owed to each Fee Collector. These virtual shares are included in the
///      effective totalSupply, which dilutes the share price for depositors —
///      automatically reflecting the fee in convertToAssets().
contract VaultWrapper is ERC20 {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────

    /// @notice Thrown when transfer() or transferFrom() is called (shares are non-transferable).
    error TransfersDisabled();

    /// @notice Thrown when approve() is called (approvals are disabled).
    error ApprovalsDisabled();

    /// @notice Thrown when a deposit is made with a zero-address fee collector.
    error ZeroFeeCollector();

    /// @notice Thrown when a deposit or withdrawal specifies zero assets.
    error ZeroAssets();

    /// @notice Thrown when a mint or redeem specifies zero shares, or the computed shares are zero.
    error ZeroShares();

    /// @notice Thrown when a redeem or withdraw exceeds the owner's share balance.
    error InsufficientBalance();

    /// @notice Thrown when msg.sender is not the share owner on redeem/withdraw.
    error NotShareOwner();

    // ──────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────

    /// @notice Emitted when a depositor's fee collector is rotated to a new address.
    /// @param depositor    The depositor whose collector changed.
    /// @param oldCollector The previous fee collector.
    /// @param newCollector The new fee collector.
    event FeeCollectorChanged(
        address indexed depositor,
        address indexed oldCollector,
        address indexed newCollector
    );

    /// @notice Emitted when accumulated virtual fee shares are collected and
    ///         redeemed as real assets to the fee collector.
    /// @param feeCollector  The address that received the fee assets.
    /// @param virtualShares The number of virtual shares that were redeemed.
    /// @param assets        The amount of underlying assets transferred.
    event FeesCollected(
        address indexed feeCollector,
        uint256 virtualShares,
        uint256 assets
    );

    /// @notice Emitted when pending virtual shares are settled (snapshotted)
    ///         for a fee collector during a position change.
    /// @param feeCollector  The fee collector whose shares were settled.
    /// @param virtualShares The number of virtual shares that were settled.
    event FeeSettled(
        address indexed feeCollector,
        uint256 virtualShares
    );

    // ──────────────────────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────────────────────

    /// @notice Tracks fee accrual state for a single fee collector.
    /// @dev One instance per fee collector address. Virtual shares accrue
    ///      continuously based on totalAUM, feePercentage, and elapsed time.
    ///      They are "settled" (snapshotted) before any position change.
    struct FeeCollectorState {
        /// @notice Sum of asset values of all depositors assigned to this collector
        uint256 totalAUM;
        /// @notice Timestamp of the last virtual share settlement
        uint256 lastAccrualTimestamp;
        /// @notice Accumulated virtual shares ready for collection via collectFees()
        uint256 settledVirtualShares;
    }

    // ──────────────────────────────────────────────────────────────
    // Immutables
    // ──────────────────────────────────────────────────────────────

    /// @notice The underlying ERC-4626 vault this wrapper deposits into.
    IERC4626 public immutable underlying;

    /// @notice The asset token (same as underlying.asset()).
    IERC20 public immutable asset;

    /// @notice Annual fee in basis points (1 = 0.01%, 100 = 1%, 5000 = 50%).
    uint256 public immutable feePercentage;

    // ──────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────

    /// @notice Maps each depositor to their assigned fee collector address.
    mapping(address => address) public depositorFeeCollector;

    /// @notice Maps each fee collector to their accrual state (AUM, timestamp, settled shares).
    mapping(address => FeeCollectorState) public feeCollectorStates;

    /// @notice Global sum of all settled virtual shares across all fee collectors.
    /// @dev Used in effectiveTotalSupply() to include settled (but not yet collected)
    ///      fee shares in the share price calculation.
    uint256 public totalSettledVirtualShares;

    /// @dev Ordered list of fee collectors that have ever had AUM > 0.
    ///      Used by effectiveTotalSupply() to iterate and sum pending virtual shares.
    address[] internal _activeFeeCollectors;

    /// @dev Quick lookup to avoid duplicate entries in _activeFeeCollectors.
    mapping(address => bool) internal _isFeeCollectorActive;

    // ──────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────

    /// @notice Deploy a new wrapper for the given underlying vault and fee tier.
    /// @dev Called by VaultWrapperFactory via CREATE2. The share token name and
    ///      symbol are derived from the underlying vault (e.g. "Wrapped Vault" / "wVLT").
    /// @param _underlying   Address of the underlying ERC-4626 vault.
    /// @param _feePercentage Annual fee in basis points (1–5000).
    constructor(
        address _underlying,
        uint256 _feePercentage
    )
        ERC20(
            string.concat("Wrapped ", IERC4626(_underlying).name()),
            string.concat("w", IERC4626(_underlying).symbol())
        )
    {
        underlying = IERC4626(_underlying);
        asset = IERC20(IERC4626(_underlying).asset());
        feePercentage = _feePercentage;
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

    /// @notice Always reverts — approvals are disabled for non-transferable shares.
    function approve(address, uint256) public pure override returns (bool) {
        revert ApprovalsDisabled();
    }

    // ──────────────────────────────────────────────────────────────
    // ERC-4626 View Functions
    // ──────────────────────────────────────────────────────────────

    /// @notice Total assets held by this wrapper in the underlying vault.
    /// @return The asset value of the wrapper's underlying vault share balance.
    function totalAssets() public view returns (uint256) {
        uint256 bal = underlying.balanceOf(address(this));
        if (bal == 0) return 0;
        return underlying.convertToAssets(bal);
    }

    /// @notice Compute pending (unsettled) virtual fee shares for a fee collector.
    /// @dev O(1) per collector — uses the formula:
    ///      feeAssets = AUM × feePercentage × elapsed / (10000 × 365.25 days)
    ///      then converts feeAssets to shares using the base supply ratio
    ///      (excluding pending virtual shares to avoid circular dependency).
    /// @param feeCollector The fee collector address to query.
    /// @return The number of pending virtual shares.
    function getPendingVirtualShares(address feeCollector) public view returns (uint256) {
        FeeCollectorState storage state = feeCollectorStates[feeCollector];
        if (state.totalAUM == 0 || state.lastAccrualTimestamp == 0) return 0;

        uint256 elapsed = block.timestamp - state.lastAccrualTimestamp;
        if (elapsed == 0) return 0;

        // 365.25 days = 31_557_600 seconds
        uint256 feeAssets = Math.mulDiv(
            state.totalAUM * feePercentage,
            elapsed,
            10000 * 31557600
        );
        if (feeAssets == 0) return 0;

        // Convert fee assets to shares using the base ratio (real shares + settled)
        // to avoid circular dependency between collectors
        uint256 _totalAssets = totalAssets();
        uint256 baseSupply = totalSupply() + totalSettledVirtualShares;
        if (_totalAssets == 0 || baseSupply == 0) return feeAssets;

        return Math.mulDiv(feeAssets, baseSupply, _totalAssets, Math.Rounding.Floor);
    }

    /// @notice Effective total supply including real shares, settled virtual shares,
    ///         and all pending (unsettled) virtual shares across all fee collectors.
    /// @dev This is the denominator used in convertToAssets/convertToShares so that
    ///      the share price automatically reflects fee dilution.
    /// @return The effective total supply.
    function effectiveTotalSupply() public view returns (uint256) {
        uint256 pending = 0;
        for (uint256 i = 0; i < _activeFeeCollectors.length; i++) {
            pending += getPendingVirtualShares(_activeFeeCollectors[i]);
        }
        return totalSupply() + totalSettledVirtualShares + pending;
    }

    /// @notice Convert an asset amount to wrapper shares using the effective total supply.
    /// @param assets The amount of assets to convert.
    /// @return The equivalent number of wrapper shares (rounded down).
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = effectiveTotalSupply();
        if (supply == 0) return assets;
        return Math.mulDiv(assets, supply, totalAssets(), Math.Rounding.Floor);
    }

    /// @notice Convert a share amount to assets using the effective total supply.
    /// @param shares The number of shares to convert.
    /// @return The equivalent amount of assets (rounded down).
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = effectiveTotalSupply();
        if (supply == 0) return shares;
        return Math.mulDiv(shares, totalAssets(), supply, Math.Rounding.Floor);
    }

    // ──────────────────────────────────────────────────────────────
    // ERC-4626 Preview & Max Functions
    // ──────────────────────────────────────────────────────────────

    /// @notice Preview the number of shares that would be minted for a given deposit.
    /// @param assets The amount of assets to deposit.
    /// @return The number of shares that would be minted.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Preview the number of assets required to mint a given number of shares.
    /// @dev Rounds up to ensure the caller pays enough.
    /// @param shares The number of shares to mint.
    /// @return The number of assets required.
    function previewMint(uint256 shares) external view returns (uint256) {
        uint256 supply = effectiveTotalSupply();
        if (supply == 0) return shares;
        return Math.mulDiv(shares, totalAssets(), supply, Math.Rounding.Ceil);
    }

    /// @notice Preview the number of shares that must be burned to withdraw exact assets.
    /// @dev Rounds up so the owner burns enough shares.
    /// @param assets The amount of assets to withdraw.
    /// @return The number of shares that would be burned.
    function previewWithdraw(uint256 assets) external view returns (uint256) {
        uint256 supply = effectiveTotalSupply();
        if (supply == 0) return assets;
        return Math.mulDiv(assets, supply, totalAssets(), Math.Rounding.Ceil);
    }

    /// @notice Preview the number of assets returned for redeeming a given number of shares.
    /// @param shares The number of shares to redeem.
    /// @return The number of assets that would be returned.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @notice Maximum assets that can be deposited (no cap).
    /// @param /* receiver */ Unused — included for ERC-4626 interface compliance.
    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum shares that can be minted (no cap).
    /// @param /* receiver */ Unused — included for ERC-4626 interface compliance.
    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum assets the owner can withdraw (their full position value).
    /// @param owner The address to check.
    /// @return The maximum withdrawable asset amount.
    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /// @notice Maximum shares the owner can redeem (their full balance).
    /// @param owner The address to check.
    /// @return The maximum redeemable share amount.
    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    // ──────────────────────────────────────────────────────────────
    // View Helpers
    // ──────────────────────────────────────────────────────────────

    /// @notice Get the fee collector assigned to a depositor.
    /// @param depositor The depositor address.
    /// @return The fee collector address (zero if no deposit has been made).
    function getDepositorFeeCollector(address depositor) external view returns (address) {
        return depositorFeeCollector[depositor];
    }

    /// @notice Get the full fee accrual state for a fee collector.
    /// @param feeCollector The fee collector address.
    /// @return aum                Total assets under management for this collector.
    /// @return settledShares      Settled virtual shares ready for collection.
    /// @return pendingShares      Unsettled virtual shares accruing in real-time.
    /// @return totalClaimableAssets Asset value of settled + pending virtual shares.
    function getFeeCollectorState(address feeCollector) external view returns (
        uint256 aum,
        uint256 settledShares,
        uint256 pendingShares,
        uint256 totalClaimableAssets
    ) {
        FeeCollectorState storage state = feeCollectorStates[feeCollector];
        aum = state.totalAUM;
        settledShares = state.settledVirtualShares;
        pendingShares = getPendingVirtualShares(feeCollector);
        totalClaimableAssets = convertToAssets(settledShares + pendingShares);
    }

    // ──────────────────────────────────────────────────────────────
    // Internal Helpers
    // ──────────────────────────────────────────────────────────────

    /// @dev Settle pending virtual shares for a fee collector by computing the
    ///      accrued amount and adding it to the settled total. Resets the
    ///      accrual timestamp to block.timestamp.
    /// @param feeCollector The fee collector whose virtual shares to settle.
    function _settleFeeCollector(address feeCollector) internal {
        FeeCollectorState storage state = feeCollectorStates[feeCollector];

        if (state.lastAccrualTimestamp > 0 && state.totalAUM > 0) {
            uint256 elapsed = block.timestamp - state.lastAccrualTimestamp;
            if (elapsed > 0) {
                // Inline the pending virtual shares formula to save gas
                uint256 feeAssets = Math.mulDiv(
                    state.totalAUM * feePercentage,
                    elapsed,
                    10000 * 31557600
                );

                if (feeAssets > 0) {
                    uint256 _totalAssets = totalAssets();
                    uint256 baseSupply = totalSupply() + totalSettledVirtualShares;
                    uint256 pending;
                    if (_totalAssets == 0 || baseSupply == 0) {
                        pending = feeAssets;
                    } else {
                        pending = Math.mulDiv(
                            feeAssets, baseSupply, _totalAssets, Math.Rounding.Floor
                        );
                    }

                    if (pending > 0) {
                        state.settledVirtualShares += pending;
                        totalSettledVirtualShares += pending;
                        emit FeeSettled(feeCollector, pending);
                    }
                }
            }
        }

        state.lastAccrualTimestamp = block.timestamp;
    }

    /// @dev Register a fee collector in the active set if not already tracked.
    ///      Needed so effectiveTotalSupply() can iterate over all collectors.
    /// @param feeCollector The fee collector address to register.
    function _registerFeeCollector(address feeCollector) internal {
        if (!_isFeeCollectorActive[feeCollector]) {
            _activeFeeCollectors.push(feeCollector);
            _isFeeCollectorActive[feeCollector] = true;
        }
    }

    /// @dev Shared deposit logic — handles fee collector assignment (new depositor,
    ///      same collector, or rotation), pulls assets from the caller, deposits
    ///      into the underlying vault, and mints wrapper shares to the receiver.
    /// @param assets       The amount of underlying assets to deposit.
    /// @param shares       The number of wrapper shares to mint.
    /// @param receiver     The address that receives the minted shares.
    /// @param feeCollector The fee collector assigned to this depositor.
    function _deposit(
        uint256 assets,
        uint256 shares,
        address receiver,
        address feeCollector
    ) internal {
        address oldCollector = depositorFeeCollector[receiver];

        if (oldCollector == address(0)) {
            // New depositor — assign fee collector and add to AUM
            _settleFeeCollector(feeCollector);
            _registerFeeCollector(feeCollector);
            depositorFeeCollector[receiver] = feeCollector;
            feeCollectorStates[feeCollector].totalAUM += assets;
        } else if (oldCollector == feeCollector) {
            // Same collector — settle and add new assets to AUM
            _settleFeeCollector(feeCollector);
            feeCollectorStates[feeCollector].totalAUM += assets;
        } else {
            // Rotation — settle old collector, move depositor's AUM, settle new
            _settleFeeCollector(oldCollector);
            uint256 depositorAssets = convertToAssets(balanceOf(receiver));

            // Subtract depositor's AUM from old collector (capped at 0)
            if (depositorAssets >= feeCollectorStates[oldCollector].totalAUM) {
                feeCollectorStates[oldCollector].totalAUM = 0;
            } else {
                feeCollectorStates[oldCollector].totalAUM -= depositorAssets;
            }

            _settleFeeCollector(feeCollector);
            _registerFeeCollector(feeCollector);
            feeCollectorStates[feeCollector].totalAUM += depositorAssets + assets;
            depositorFeeCollector[receiver] = feeCollector;
            emit FeeCollectorChanged(receiver, oldCollector, feeCollector);
        }

        // Pull assets from caller, approve underlying vault, and deposit
        asset.safeTransferFrom(msg.sender, address(this), assets);
        SafeERC20.forceApprove(asset, address(underlying), assets);
        underlying.deposit(assets, address(this));

        // Mint wrapper shares to receiver
        _mint(receiver, shares);
    }

    // ──────────────────────────────────────────────────────────────
    // ERC-4626 Mutative Functions
    // ──────────────────────────────────────────────────────────────

    /// @notice Deposit assets and receive wrapper shares.
    /// @dev The feeCollector parameter extends the standard ERC-4626 deposit
    ///      signature to track which address accrues fees for this depositor.
    /// @param assets       Amount of underlying assets to deposit.
    /// @param receiver     Address that receives the minted wrapper shares.
    /// @param feeCollector Address that accrues fees for this position.
    /// @return shares      Number of wrapper shares minted.
    function deposit(   
        uint256 assets,
        address receiver,
        address feeCollector
    ) external returns (uint256 shares) {
        if (feeCollector == address(0)) revert ZeroFeeCollector();
        if (assets == 0) revert ZeroAssets();

        // Snapshot share price before any state changes
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();

        _deposit(assets, shares, receiver, feeCollector);
    }

    /// @notice Mint exact wrapper shares by depositing the required assets.
    /// @param shares       Number of wrapper shares to mint.
    /// @param receiver     Address that receives the minted shares.
    /// @param feeCollector Address that accrues fees for this position.
    /// @return assets      Amount of underlying assets pulled from the caller.
    function mint(
        uint256 shares,
        address receiver,
        address feeCollector
    ) external returns (uint256 assets) {
        if (feeCollector == address(0)) revert ZeroFeeCollector();
        if (shares == 0) revert ZeroShares();

        // Round up so the caller pays enough assets for the requested shares
        uint256 supply = effectiveTotalSupply();
        if (supply == 0) {
            assets = shares;
        } else {
            assets = Math.mulDiv(shares, totalAssets(), supply, Math.Rounding.Ceil);
        }
        if (assets == 0) revert ZeroAssets();

        _deposit(assets, shares, receiver, feeCollector);
    }

    /// @notice Redeem wrapper shares for underlying assets.
    /// @param shares   Number of wrapper shares to redeem.
    /// @param receiver Address that receives the withdrawn assets.
    /// @param owner    Address whose shares are being redeemed.
    /// @return assets  Amount of underlying assets returned.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        // Approvals are disabled so only the owner can redeem their own shares
        if (msg.sender != owner) revert NotShareOwner();
        if (shares == 0) revert ZeroShares();
        if (balanceOf(owner) < shares) revert InsufficientBalance();

        assets = convertToAssets(shares);
        if (assets == 0) revert ZeroAssets();

        // Settle fee collector before state mutation
        address feeCollector = depositorFeeCollector[owner];
        if (feeCollector != address(0)) {
            _settleFeeCollector(feeCollector);
            if (assets >= feeCollectorStates[feeCollector].totalAUM) {
                feeCollectorStates[feeCollector].totalAUM = 0;
            } else {
                feeCollectorStates[feeCollector].totalAUM -= assets;
            }
        }

        _burn(owner, shares);
        underlying.withdraw(assets, receiver, address(this));
    }

    /// @notice Withdraw exact assets by burning the required wrapper shares.
    /// @param assets   Amount of underlying assets to withdraw.
    /// @param receiver Address that receives the withdrawn assets.
    /// @param owner    Address whose shares are being burned.
    /// @return shares  Number of wrapper shares burned.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares) {
        // Approvals are disabled so only the owner can withdraw their own shares
        if (msg.sender != owner) revert NotShareOwner();
        if (assets == 0) revert ZeroAssets();

        // Round up shares so the owner burns enough for the exact asset withdrawal
        uint256 supply = effectiveTotalSupply();
        if (supply == 0) {
            shares = assets;
        } else {
            shares = Math.mulDiv(assets, supply, totalAssets(), Math.Rounding.Ceil);
        }
        if (shares == 0) revert ZeroShares();
        if (balanceOf(owner) < shares) revert InsufficientBalance();

        // Settle fee collector before state mutation
        address feeCollector = depositorFeeCollector[owner];
        if (feeCollector != address(0)) {
            _settleFeeCollector(feeCollector);
            if (assets >= feeCollectorStates[feeCollector].totalAUM) {
                feeCollectorStates[feeCollector].totalAUM = 0;
            } else {
                feeCollectorStates[feeCollector].totalAUM -= assets;
            }
        }

        _burn(owner, shares);
        underlying.withdraw(assets, receiver, address(this));
    }

    // ──────────────────────────────────────────────────────────────
    // Fee Collection
    // ──────────────────────────────────────────────────────────────

    /// @notice Collect accumulated virtual fee shares for a fee collector.
    /// @dev Permissionless — anyone can call, but assets are always sent to the
    ///      feeCollector address. Settles pending virtual shares, calculates
    ///      their asset value, clears the settled state, and withdraws from the
    ///      underlying vault directly to the fee collector.
    /// @param feeCollector The fee collector whose fees to collect.
    function collectFees(address feeCollector) external {
        // Settle any pending (unsettled) virtual shares first
        _settleFeeCollector(feeCollector);

        FeeCollectorState storage state = feeCollectorStates[feeCollector];
        uint256 virtualShares = state.settledVirtualShares;

        // No-op when nothing to collect
        if (virtualShares == 0) return;

        // Calculate asset value BEFORE clearing state so effectiveTotalSupply
        // still includes the virtual shares for accurate pricing
        uint256 assets = convertToAssets(virtualShares);

        // Clear settled virtual shares from both per-collector and global totals
        state.settledVirtualShares = 0;
        totalSettledVirtualShares -= virtualShares;

        // Withdraw directly from the underlying vault to the fee collector
        if (assets > 0) {
            underlying.withdraw(assets, feeCollector, address(this));
        }

        emit FeesCollected(feeCollector, virtualShares, assets);
    }
}
