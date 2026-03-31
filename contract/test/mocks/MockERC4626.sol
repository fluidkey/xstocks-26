// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/**
 * Simple mintable ERC20 used as the underlying asset for MockERC4626.
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/**
 * Minimal ERC-4626 vault wrapping a MockERC20 asset.
 * Uses a 1:1 share ratio (no custom logic) — just the default
 * OpenZeppelin ERC4626 behavior for isolated testing.
 */
contract MockERC4626 is ERC4626 {
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(asset_) {}
}
