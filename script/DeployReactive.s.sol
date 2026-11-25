// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { SentinelReactive } from "../src/SentinelReactive.sol";

/// @notice Step 2, Reactive Lasna: the reactive contract.
/// forge script script/DeployReactive.s.sol --rpc-url $RPC_LASNA --broadcast
contract DeployReactive is Script {
    function run() external returns (address reactive) {
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address feed = vm.envAddress("PRICE_FEED");
        uint256 destChainId = vm.envUint("DEST_CHAIN_ID");
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast();
        reactive = address(new SentinelReactive(originChainId, feed, destChainId, owner));
        vm.stopBroadcast();
        console2.log("REACTIVE", reactive);
    }
}
