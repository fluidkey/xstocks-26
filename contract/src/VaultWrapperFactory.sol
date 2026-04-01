// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {VaultWrapper} from "./VaultWrapper.sol";

/// @title VaultWrapperFactory
/// @notice Permissionless singleton factory that deploys VaultWrapper instances
///         via CREATE2. Each unique (underlyingVault, feePercentage, feeCollector)
///         triple maps to exactly one deterministic wrapper address.
contract VaultWrapperFactory {

    /// @notice Thrown when feePercentage is 0 or exceeds 5000 bps (50%).
    error InvalidFeePercentage();

    /// @notice Thrown when underlyingVault is the zero address.
    error InvalidUnderlyingVault();

    /// @notice Thrown when feeCollector is the zero address.
    error InvalidFeeCollector();

    /// @notice Emitted when a new VaultWrapper is deployed.
    /// @param underlyingVault The ERC-4626 vault the wrapper sits in front of.
    /// @param wrapper         The newly deployed VaultWrapper address.
    /// @param asset           The underlying asset token.
    /// @param feePercentage   The fee tier in basis points.
    /// @param feeCollector    The address that receives fees.
    event WrapperDeployed(
        address indexed underlyingVault,
        address indexed wrapper,
        address asset,
        uint256 feePercentage,
        address feeCollector
    );

    /// @notice Maps CREATE2 salt to deployed VaultWrapper address.
    mapping(bytes32 => address) public deployedWrappers;

    /// @notice Deploy a new VaultWrapper or return the existing one.
    /// @param underlyingVault The ERC-4626 vault to wrap.
    /// @param feePercentage   Fee in basis points (1–5000).
    /// @param feeCollector    Address that receives collected fees.
    /// @return wrapper The deployed (or existing) VaultWrapper address.
    function deploy(
        address underlyingVault,
        uint256 feePercentage,
        address feeCollector
    ) external returns (address wrapper) {
        if (underlyingVault == address(0)) revert InvalidUnderlyingVault();
        if (feePercentage == 0 || feePercentage > 5000) revert InvalidFeePercentage();
        if (feeCollector == address(0)) revert InvalidFeeCollector();

        bytes32 salt = keccak256(abi.encodePacked(underlyingVault, feePercentage, feeCollector));

        // Return existing wrapper if already deployed
        wrapper = deployedWrappers[salt];
        if (wrapper != address(0)) return wrapper;

        // Deploy via CREATE2 for deterministic addressing
        wrapper = address(new VaultWrapper{salt: salt}(underlyingVault, feePercentage, feeCollector));
        deployedWrappers[salt] = wrapper;

        address assetAddr = address(VaultWrapper(wrapper).asset());
        emit WrapperDeployed(underlyingVault, wrapper, assetAddr, feePercentage, feeCollector);
    }

    /// @notice Compute the deterministic CREATE2 address without deploying.
    /// @param underlyingVault The ERC-4626 vault address.
    /// @param feePercentage   The fee tier in basis points.
    /// @param feeCollector    The fee collector address.
    /// @return The predicted wrapper address.
    function computeAddress(
        address underlyingVault,
        uint256 feePercentage,
        address feeCollector
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(underlyingVault, feePercentage, feeCollector));

        bytes memory constructorArgs = abi.encode(underlyingVault, feePercentage, feeCollector);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(VaultWrapper).creationCode, constructorArgs)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)
        );
        return address(uint160(uint256(hash)));
    }
}
