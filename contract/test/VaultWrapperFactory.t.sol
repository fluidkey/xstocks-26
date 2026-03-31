// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {VaultWrapper} from "../src/VaultWrapper.sol";
import {MockERC20, MockERC4626} from "./mocks/MockERC4626.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

contract VaultWrapperFactoryTest is Test {
    VaultWrapperFactory public factory;
    MockERC20 public asset;
    MockERC4626 public underlyingVault;

    function setUp() public {
        factory = new VaultWrapperFactory();
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(IERC20(address(asset)), "Test Vault", "vTT");
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 1: Factory Deploy Idempotence
    // **Validates: Requirements 1.2**
    // ---------------------------------------------------------------

    function testFuzz_deployIdempotence(uint256 feePercentage) public {
        feePercentage = bound(feePercentage, 1, 5000);

        address first = factory.deploy(address(underlyingVault), feePercentage);
        address second = factory.deploy(address(underlyingVault), feePercentage);

        assertEq(first, second, "Duplicate deploy must return the same address");
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 2: Factory CREATE2 Determinism
    // **Validates: Requirements 1.3, 1.4**
    // ---------------------------------------------------------------

    function testFuzz_create2Determinism(uint256 feePercentage) public {
        feePercentage = bound(feePercentage, 1, 5000);

        address predicted = factory.computeAddress(address(underlyingVault), feePercentage);
        address deployed = factory.deploy(address(underlyingVault), feePercentage);

        assertEq(predicted, deployed, "computeAddress must match deployed address");
    }

    // ---------------------------------------------------------------
    // Feature: safe-4626-vault-module, Property 3: Fee Percentage Validation
    // **Validates: Requirements 4.4**
    // ---------------------------------------------------------------

    function testFuzz_feePercentageValidation(uint256 feePercentage) public {
        if (feePercentage == 0 || feePercentage > 5000) {
            vm.expectRevert(VaultWrapperFactory.InvalidFeePercentage.selector);
            factory.deploy(address(underlyingVault), feePercentage);
        } else {
            address wrapper = factory.deploy(address(underlyingVault), feePercentage);
            assertTrue(wrapper != address(0), "Valid fee must produce a non-zero wrapper");
        }
    }

    // ---------------------------------------------------------------
    // Unit tests for VaultWrapperFactory
    // ---------------------------------------------------------------

    function test_deployEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit VaultWrapperFactory.WrapperDeployed(
            address(underlyingVault),
            factory.computeAddress(address(underlyingVault), 100),
            address(asset),
            100
        );
        factory.deploy(address(underlyingVault), 100);
    }

    function test_deployBoundaryFee1() public {
        address wrapper = factory.deploy(address(underlyingVault), 1);
        assertTrue(wrapper != address(0), "Fee=1 should deploy successfully");
    }

    function test_deployBoundaryFee5000() public {
        address wrapper = factory.deploy(address(underlyingVault), 5000);
        assertTrue(wrapper != address(0), "Fee=5000 should deploy successfully");
    }

    function test_deployInvalidFee0() public {
        vm.expectRevert(VaultWrapperFactory.InvalidFeePercentage.selector);
        factory.deploy(address(underlyingVault), 0);
    }

    function test_deployInvalidFee5001() public {
        vm.expectRevert(VaultWrapperFactory.InvalidFeePercentage.selector);
        factory.deploy(address(underlyingVault), 5001);
    }

    function test_deployZeroAddressVault() public {
        vm.expectRevert(VaultWrapperFactory.InvalidUnderlyingVault.selector);
        factory.deploy(address(0), 100);
    }
}
