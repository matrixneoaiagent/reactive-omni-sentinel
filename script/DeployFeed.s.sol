// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { PriceFeedOrigin } from "../src/PriceFeedOrigin.sol";

/// @notice Step 1, Base Sepolia: the origin feed.
/// forge script script/DeployFeed.s.sol --rpc-url $RPC_BASE --broadcast
contract DeployFeed is Script {
    function run() external returns (address feed) {
        address publisher = vm.envAddress("OWNER");
        vm.startBroadcast();
        feed = address(new PriceFeedOrigin(publisher));
        vm.stopBroadcast();
        console2.log("PRICE_FEED", feed);
    }
}
