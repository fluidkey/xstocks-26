// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";
import {SafeEarnModule} from "../src/SafeEarnModule.sol";

/// @notice Deploys the full stack: VaultWrapperFactory + SafeEarnModule.
///         The factory is deployed first so its address can be passed to the module constructor.
///
/// Usage:
///   1. Copy .env.example to .env and fill in values
///   2. Deploy (Factory + Module are auto-verified):
///      forge script script/Deploy.s.sol:DeployScript \
///        --rpc-url mainnet \
///        --broadcast \
///        --verify \
///        -vvvv
///
///   3. Verify a VaultWrapper deployed by the factory (not auto-verified):
///      source .env && forge verify-contract <WRAPPER_ADDRESS> src/VaultWrapper.sol:VaultWrapper \
///        --constructor-args $(cast abi-encode "constructor(address,uint256,address)" <UNDERLYING_VAULT> <FEE_BPS> <FEE_COLLECTOR>) \
///        --rpc-url mainnet \
///        --etherscan-api-key $ETHERSCAN_API_KEY \
///        --watch
contract DeployScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address authorizedRelayer = vm.envAddress("AUTHORIZED_RELAYER");
        address wrappedNative = vm.envAddress("WRAPPED_NATIVE");
        address moduleOwner = vm.envAddress("MODULE_OWNER");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy factory first — no constructor args, permissionless singleton
        VaultWrapperFactory factory = new VaultWrapperFactory();
        console.log("VaultWrapperFactory deployed at:", address(factory));

        // Deploy module, passing the factory address from the previous step
        SafeEarnModule module = new SafeEarnModule(
            authorizedRelayer,
            wrappedNative,
            moduleOwner,
            address(factory)
        );
        console.log("SafeEarnModule deployed at:", address(module));

        vm.stopBroadcast();

        console.log("\n--- Deployment Summary ---");
        console.log("Factory:", address(factory));
        console.log("Module: ", address(module));
        console.log("Owner:  ", moduleOwner);
        console.log("Relayer:", authorizedRelayer);
        console.log("WETH:   ", wrappedNative);
    }
}
