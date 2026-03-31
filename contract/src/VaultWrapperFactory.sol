// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultWrapper} from "./VaultWrapper.sol";

/// @title VaultWrapperFactory
/// @notice Ownerless, permissionless singleton factory that deploys VaultWrapper
///         instances via CREATE2. Each unique (underlyingVault, feePercentage)
///         pair maps to exactly one deterministic wrapper address.
/// @dev Salt = keccak256(abi.encodePacked(underlyingVault, feePercentage)).
///      Duplicate deploy calls are idempotent — they return the existing address.
contract VaultWrapperFactory {

    /// @notice Thrown when feePercentage is 0 or exceeds 5000 bps (50%).
    error InvalidFeePercentage();

    /// @notice Thrown when underlyingVault is the zero address.
    error InvalidUnderlyingVault();

    /// @notice Emitted when a new VaultWrapper is deployed.
    /// @param underlyingVault The ERC-4626 vault the wrapper sits in front of.
    /// @param wrapper         The newly deployed VaultWrapper address.
    /// @param asset           The underlying asset token (= underlyingVault.asset()).
    /// @param feePercentage   The annual fee tier in basis points.
    event WrapperDeployed(
        address indexed underlyingVault,
        address indexed wrapper,
        address asset,
        uint256 feePercentage
    );

    /// @notice Maps CREATE2 salt → deployed VaultWrapper address for O(1) lookup.
    mapping(bytes32 => address) public deployedWrappers;

    /// @notice Deploy a new VaultWrapper or return the existing one for the given pair.
    /// @dev Idempotent — if a wrapper already exists for this (vault, fee) pair,
    ///      the existing address is returned without deploying a new contract.
    /// @param underlyingVault The ERC-4626 vault to wrap. Must not be address(0).
    /// @param feePercentage   Annual fee in basis points. Must be in [1, 5000].
    /// @return wrapper The deployed (or existing) VaultWrapper address.
    function deploy(
        address underlyingVault,
        uint256 feePercentage
    ) external returns (address wrapper) {
        if (underlyingVault == address(0)) revert InvalidUnderlyingVault();
        if (feePercentage == 0 || feePercentage > 5000) revert InvalidFeePercentage();

        bytes32 salt = keccak256(abi.encodePacked(underlyingVault, feePercentage));

        // Return existing wrapper if already deployed
        wrapper = deployedWrappers[salt];
        if (wrapper != address(0)) return wrapper;

        // Deploy via CREATE2 for deterministic addressing
        wrapper = address(new VaultWrapper{salt: salt}(underlyingVault, feePercentage));
        deployedWrappers[salt] = wrapper;

        address assetAddr = address(VaultWrapper(wrapper).asset());
        emit WrapperDeployed(underlyingVault, wrapper, assetAddr, feePercentage);
    }

    /// @notice Compute the deterministic CREATE2 address without deploying.
    /// @dev Uses the same salt derivation as deploy(). Useful for off-chain
    ///      address prediction and for autoWithdraw to check if a wrapper exists.
    /// @param underlyingVault The ERC-4626 vault address.
    /// @param feePercentage   The fee tier in basis points.
    /// @return The predicted wrapper address.
    function computeAddress(
        address underlyingVault,
        uint256 feePercentage
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(underlyingVault, feePercentage));

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(VaultWrapper).creationCode,
                abi.encode(underlyingVault, feePercentage)
            )
        );

        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), salt, initCodeHash
                        )
                    )
                )
            )
        );
    }
}
