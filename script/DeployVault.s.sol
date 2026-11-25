// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { IPayable } from "reactive-lib/interfaces/IPayable.sol";
import { SentinelVault } from "../src/SentinelVault.sol";

/// @notice Step 3, Base Sepolia: the vault, bound to the reactive contract.
/// forge script script/DeployVault.s.sol --rpc-url $RPC_BASE --broadcast
contract DeployVault is Script {
    function run() external returns (address vault) {
        address proxy = vm.envAddress("CALLBACK_PROXY");
        address reactive = vm.envAddress("REACTIVE_ADDRESS");

        vm.startBroadcast();
        vault = address(new SentinelVault(IPayable(payable(proxy)), reactive));
        vm.stopBroadcast();
        console2.log("VAULT", vault);
    }
}
