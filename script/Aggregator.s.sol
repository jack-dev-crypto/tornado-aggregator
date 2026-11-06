// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Aggregator} from "../src/Aggregator.sol";

contract Deploy is Script {
    function run() external returns (Aggregator aggregator) {
        // Both addresses are hardcoded constants, so this only makes sense on Ethereum mainnet (or a mainnet fork).
        require(block.chainid == 1, "Deploy: mainnet only");

        vm.startBroadcast();
        aggregator = new Aggregator();
        vm.stopBroadcast();

        // Post-deploy sanity: the hardcoded dependencies must have code on this chain.
        require(address(aggregator.universalResolver()).code.length > 0, "Deploy: no Universal Resolver");
        require(address(aggregator.relayerRegistry()).code.length > 0, "Deploy: no RelayerRegistry");

        console.log("Aggregator deployed at:", address(aggregator));
    }
}
