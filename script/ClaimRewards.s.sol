// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "../lib/forge-std/src/Script.sol";

interface IVault {
    function claimRewards() external;
}

contract ClaimRewards is Script {
    address constant VAULT = 0x526dAE03f78C6295D2DB92f20268abB509F88095;

    function run() external {
        vm.startBroadcast();

        // Only callable by the deployer (owner)
        IVault(VAULT).claimRewards();

        vm.stopBroadcast();

        console.log("Rewards claimed!");
        console.log("  Aave incentive rewards sent to owner");
    }
}
