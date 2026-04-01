// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title VaultWrapper
/// @notice Non-transferable ERC-4626 wrapper that sits between depositors and an
///         underlying ERC-4626 vault. Accrues a percentage fee on yield via a
///         totalAssets() override — the fee collector and rate are fixed at deploy.
/// @dev Fee mechanism: totalAssets() reports grossAssets minus the fee portion of
///      any positive yield (grossAssets - totalDeposited). This automatically
///      dilutes the share price to reflect the fee without any virtual shares,
///      per-depositor tracking, or settlement logic.
contract VaultWrapper is ERC20 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ──────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────

    /// @notice Thrown when transfer/transferFrom is called (shares are non-transferable).
    error TransfersDisabled();

    /// @notice Thrown when approve is called (approvals are disabled).
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

    /// @notice Emitted when accumulated fees are collected to the fee collector.
    /// @param feeCollector Address that received the fee assets.
    /// @param yield        Total yield that was subject to the fee.
    /// @param feeAssets    Amount of assets sent to the fee collector.
    event FeesCollected(
        address indexed feeCollector,
        uint256 yield,
        uint256 feeAssets
    );

    // ──────────────────────────────────────────────────────────────
    // Immutables
    // ──────────────────────────────────────────────────────────────

    /// @notice The underlying ERC-4626 vault this wrapper deposits into.
    IERC4626 public immutable underlying;

    /// @notice The asset token (same as underlying.asset()).
    IERC20 public immutable asset;

    /// @notice Annual fee in basis points applied to yield (e.g. 100 = 1%).
    uint256 public immutable feePercentage;

    /// @notice Address that receives collected fees — set once at deploy.
    address public immutable feeCollector;

    // ──────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────

    /// @notice Running total of net deposits. Used to compute yield.
    /// @dev Increased on deposit, decreased on withdraw/redeem.
    ///      yield = grossAssets - totalDeposited (when positive).
    uint256 public totalDeposited;

    /// @dev Virtual offset for share conversion math to prevent the ERC-4626
    ///      inflation / donation attack. Set once in constructor from asset decimals.
    ///      Uses the same asymmetric pattern as OpenZeppelin ERC4626 — large
    ///      offset on supply, +1 on assets — so convertToAssets can never
    ///      exceed real totalAssets. The attacker must donate OFFSET × the
    ///      victim's deposit to steal meaningful value.
    uint256 private _virtualShareOffset;

    // ──────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────

    /// @notice Deploy a new wrapper for the given underlying vault, fee tier, and collector.
    /// @param _underlying     Address of the underlying ERC-4626 vault.
    /// @param _feePercentage  Fee in basis points applied to yield (1–5000).
    /// @param _feeCollector   Address that receives collected fees.
    constructor(
        address _underlying,
        uint256 _feePercentage,
        address _feeCollector
    )
        ERC20("VaultWrapper", "vWRP")
    {
        underlying = IERC4626(_underlying);
        asset = IERC20(IERC4626(_underlying).asset());
        feePercentage = _feePercentage;
        feeCollector = _feeCollector;
        _virtualShareOffset = 10 ** uint256(IERC20Metadata(IERC4626(_underlying).asset()).decimals());
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

    /// @notice Decimals match the underlying asset.
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(address(asset)).decimals();
    }

    // ──────────────────────────────────────────────────────────────
    // ERC-4626 View Functions
    // ──────────────────────────────────────────────────────────────

    /// @notice Gross asset value held in the underlying vault (before fee deduction).
    function grossAssets() public view returns (uint256) {
        uint256 bal = underlying.balanceOf(address(this));
        if (bal == 0) return 0;
        return underlying.convertToAssets(bal);
    }

    /// @notice Total assets after deducting the fee portion of any positive yield.
    /// @dev This is the core fee mechanism — by reporting less than grossAssets,
    ///      the share price automatically reflects the fee.
    function totalAssets() public view returns (uint256) {
        uint256 gross = grossAssets();
        if (gross <= totalDeposited) return gross;

        // Fee only applies to positive yield
        uint256 yield = gross - totalDeposited;
        uint256 fee = yield.mulDiv(feePercentage, 10000, Math.Rounding.Floor);
        return gross - fee;
    }

    /// @notice Convert an asset amount to wrapper shares.
    /// @dev Includes virtual offset to prevent the inflation/donation attack.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(
            totalSupply() + _virtualShareOffset,
            totalAssets() + 1,
            Math.Rounding.Floor
        );
    }

    /// @notice Convert a share amount to assets.
    /// @dev Includes virtual offset to prevent the inflation/donation attack.
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
    function previewMint(uint256 shares) external view returns (uint256) {
        return shares.mulDiv(
            totalAssets() + 1,
            totalSupply() + _virtualShareOffset,
            Math.Rounding.Ceil
        );
    }

    /// @notice Preview the shares burned to withdraw exact assets.
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

    /// @notice Maximum assets that can be deposited (no cap).
    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum shares that can be minted (no cap).
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
    // ERC-4626 Mutative Functions
    // ──────────────────────────────────────────────────────────────

    /// @notice Deposit assets and receive wrapper shares.
    /// @param assets   Amount of underlying assets to deposit.
    /// @param receiver Address that receives the minted wrapper shares.
    /// @return shares  Number of wrapper shares minted.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();

        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();

        // Pull assets, deposit into underlying, mint wrapper shares
        asset.safeTransferFrom(msg.sender, address(this), assets);
        SafeERC20.forceApprove(asset, address(underlying), assets);
        underlying.deposit(assets, address(this));

        totalDeposited += assets;
        _mint(receiver, shares);
    }

    /// @notice Mint exact wrapper shares by depositing the required assets.
    /// @param shares   Number of wrapper shares to mint.
    /// @param receiver Address that receives the minted shares.
    /// @return assets  Amount of underlying assets pulled from the caller.
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();

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

        totalDeposited += assets;
        _mint(receiver, shares);
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
        if (msg.sender != owner) revert NotShareOwner();
        if (shares == 0) revert ZeroShares();
        if (balanceOf(owner) < shares) revert InsufficientBalance();

        assets = convertToAssets(shares);
        if (assets == 0) revert ZeroAssets();

        _burn(owner, shares);
        underlying.withdraw(assets, receiver, address(this));

        // Reduce deposit baseline — floor at zero to handle rounding
        totalDeposited = totalDeposited > assets ? totalDeposited - assets : 0;
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
        if (msg.sender != owner) revert NotShareOwner();
        if (assets == 0) revert ZeroAssets();

        // Round up shares so the owner burns enough for the exact asset withdrawal
        shares = assets.mulDiv(
            totalSupply() + _virtualShareOffset,
            totalAssets() + 1,
            Math.Rounding.Ceil
        );
        if (shares == 0) revert ZeroShares();
        if (balanceOf(owner) < shares) revert InsufficientBalance();

        _burn(owner, shares);
        underlying.withdraw(assets, receiver, address(this));

        totalDeposited = totalDeposited > assets ? totalDeposited - assets : 0;
    }

    // ──────────────────────────────────────────────────────────────
    // Fee Collection
    // ──────────────────────────────────────────────────────────────

    /// @notice Collect accrued fees and send to the fee collector.
    /// @dev Permissionless — anyone can call, assets always go to feeCollector.
    ///      Resets the deposit baseline so future yield measurement starts fresh.
    function collectFees() external {
        uint256 gross = grossAssets();
        if (gross <= totalDeposited) return;

        uint256 yield = gross - totalDeposited;
        uint256 feeAssets = yield.mulDiv(feePercentage, 10000, Math.Rounding.Floor);
        if (feeAssets == 0) return;

        // Withdraw fee from underlying vault directly to fee collector
        underlying.withdraw(feeAssets, feeCollector, address(this));

        // Reset baseline so yield after collection starts from zero
        totalDeposited = gross - feeAssets;

        emit FeesCollected(feeCollector, yield, feeAssets);
    }
}
