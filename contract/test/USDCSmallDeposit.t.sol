// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {VaultWrapper} from "../src/VaultWrapper.sol";
import {MockERC20, MockERC4626} from "./mocks/MockERC4626.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Reproduces the mainnet bug: deposit 1 USDC, no yield, try to redeem → reverts.
contract USDCSmallDepositTest is Test {
    VaultWrapperFactory public factory;
    MockERC20 public usdc;
    MockERC4626 public underlyingVault;
    VaultWrapper public wrapper;

    address constant FEE_COLLECTOR = address(0xFEE);
    address constant DEPOSITOR = address(0xDEAD);

    function setUp() public {
        factory = new VaultWrapperFactory();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        underlyingVault = new MockERC4626(IERC20(address(usdc)), "Morpho USDC", "mUSDC");
        wrapper = VaultWrapper(factory.deploy(address(underlyingVault), 100, FEE_COLLECTOR));
    }

    /// @notice Exact mainnet scenario: deposit 1 USDC, no yield, redeem all shares.
    function test_deposit1USDCThenRedeemAll() public {
        uint256 depositAmount = 1e6; // 1 USDC

        usdc.mint(DEPOSITOR, depositAmount);

        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        console.log("Shares minted:", shares);
        console.log("totalSupply:", wrapper.totalSupply());
        console.log("totalAssets:", wrapper.totalAssets());
        console.log("convertToAssets(shares):", wrapper.convertToAssets(shares));
        console.log("balanceOf(DEPOSITOR):", wrapper.balanceOf(DEPOSITOR));

        // Try to redeem all shares
        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);

        console.log("Returned:", returned);
        assertGt(returned, 0, "Must get something back");
        assertApproxEqAbs(returned, depositAmount, 2, "Should get back ~1 USDC");
    }

    /// @notice Same but with withdraw instead of redeem.
    function test_deposit1USDCThenWithdrawAll() public {
        uint256 depositAmount = 1e6;

        usdc.mint(DEPOSITOR, depositAmount);

        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, DEPOSITOR);

        uint256 maxAssets = wrapper.convertToAssets(wrapper.balanceOf(DEPOSITOR));
        console.log("maxAssets withdrawable:", maxAssets);

        wrapper.withdraw(maxAssets, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(DEPOSITOR), 0, "Should have zero shares");
    }

    /// @notice Edge case: deposit 1 wei of USDC.
    function test_deposit1WeiUSDC() public {
        usdc.mint(DEPOSITOR, 1);

        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), 1);
        uint256 shares = wrapper.deposit(1, DEPOSITOR);
        vm.stopPrank();

        console.log("Shares for 1 wei:", shares);
        console.log("convertToAssets:", wrapper.convertToAssets(shares));

        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        console.log("Returned for 1 wei:", returned);

        assertApproxEqAbs(returned, 1, 1, "Should get back ~1 wei");
    }

    /// @notice Simulate what happens if underlying vault loses 1 wei on round-trip
    ///         (common with Morpho/Aave due to share rounding).
    function test_deposit1USDCUnderlyingLoses1Wei() public {
        uint256 depositAmount = 1e6;

        usdc.mint(DEPOSITOR, depositAmount);

        vm.startPrank(DEPOSITOR);
        usdc.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, DEPOSITOR);
        vm.stopPrank();

        // Simulate underlying vault rounding: remove 1 wei from vault balance
        // This mimics Morpho/Aave where convertToAssets rounds down
        uint256 vaultBal = usdc.balanceOf(address(underlyingVault));
        vm.prank(address(underlyingVault));
        usdc.transfer(address(1), 1);

        console.log("totalAssets after rounding loss:", wrapper.totalAssets());
        console.log("convertToAssets(shares):", wrapper.convertToAssets(shares));

        // Should still be able to redeem
        vm.prank(DEPOSITOR);
        uint256 returned = wrapper.redeem(shares, DEPOSITOR, DEPOSITOR);
        assertGt(returned, 0, "Must be able to redeem even with 1 wei rounding loss");
    }
}
