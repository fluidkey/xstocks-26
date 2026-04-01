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

    address constant FEE_COLLECTOR = address(0xFEE);

    function setUp() public {
        factory = new VaultWrapperFactory();
        asset = new MockERC20("Test Token", "TT", 18);
        underlyingVault = new MockERC4626(IERC20(address(asset)), "Test Vault", "vTT");
    }

    // ---------------------------------------------------------------
    // Deploy Idempotence
    // ---------------------------------------------------------------

    function testFuzz_deployIdempotence(uint256 feePercentage) public {
        feePercentage = bound(feePercentage, 1, 5000);

        address first = factory.deploy(address(underlyingVault), feePercentage, FEE_COLLECTOR);
        address second = factory.deploy(address(underlyingVault), feePercentage, FEE_COLLECTOR);

        assertEq(first, second, "Duplicate deploy must return the same address");
    }

    // ---------------------------------------------------------------
    // CREATE2 Determinism
    // ---------------------------------------------------------------

    function testFuzz_create2Determinism(uint256 feePercentage) public {
        feePercentage = bound(feePercentage, 1, 5000);

        address predicted = factory.computeAddress(address(underlyingVault), feePercentage, FEE_COLLECTOR);
        address deployed = factory.deploy(address(underlyingVault), feePercentage, FEE_COLLECTOR);

        assertEq(predicted, deployed, "computeAddress must match deployed address");
    }

    // ---------------------------------------------------------------
    // Fee Percentage Validation
    // ---------------------------------------------------------------

    function testFuzz_feePercentageValidation(uint256 feePercentage) public {
        if (feePercentage == 0 || feePercentage > 5000) {
            vm.expectRevert(VaultWrapperFactory.InvalidFeePercentage.selector);
            factory.deploy(address(underlyingVault), feePercentage, FEE_COLLECTOR);
        } else {
            address wrapper = factory.deploy(address(underlyingVault), feePercentage, FEE_COLLECTOR);
            assertTrue(wrapper != address(0), "Valid fee must produce a non-zero wrapper");
        }
    }

    // ---------------------------------------------------------------
    // Different fee collectors produce different wrappers
    // ---------------------------------------------------------------

    function test_differentFeeCollectorsDifferentWrappers() public {
        address wrapper1 = factory.deploy(address(underlyingVault), 100, address(0xAAA));
        address wrapper2 = factory.deploy(address(underlyingVault), 100, address(0xBBB));

        assertTrue(wrapper1 != wrapper2, "Different fee collectors must produce different wrappers");
    }

    // ---------------------------------------------------------------
    // Boundary and error tests
    // ---------------------------------------------------------------

    function test_deployBoundaryFee1() public {
        address wrapper = factory.deploy(address(underlyingVault), 1, FEE_COLLECTOR);
        assertTrue(wrapper != address(0));
    }

    function test_deployBoundaryFee5000() public {
        address wrapper = factory.deploy(address(underlyingVault), 5000, FEE_COLLECTOR);
        assertTrue(wrapper != address(0));
    }

    function test_deployInvalidFee0() public {
        vm.expectRevert(VaultWrapperFactory.InvalidFeePercentage.selector);
        factory.deploy(address(underlyingVault), 0, FEE_COLLECTOR);
    }

    function test_deployInvalidFee5001() public {
        vm.expectRevert(VaultWrapperFactory.InvalidFeePercentage.selector);
        factory.deploy(address(underlyingVault), 5001, FEE_COLLECTOR);
    }

    function test_deployZeroAddressVault() public {
        vm.expectRevert(VaultWrapperFactory.InvalidUnderlyingVault.selector);
        factory.deploy(address(0), 100, FEE_COLLECTOR);
    }

    function test_deployZeroFeeCollector() public {
        vm.expectRevert(VaultWrapperFactory.InvalidFeeCollector.selector);
        factory.deploy(address(underlyingVault), 100, address(0));
    }
}
