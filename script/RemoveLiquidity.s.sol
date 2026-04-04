// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "../lib/forge-std/src/Script.sol";

interface IVault {
    function removeLiquidityAndWithdraw(uint256 positionId, uint128 liquidity) external;
}

contract RemoveLiquidity is Script {
    address constant VAULT = 0x526dAE03f78C6295D2DB92f20268abB509F88095;

    // From the AddLiquidity script output
    uint256 constant POSITION_ID = 79097;
    uint128 constant LIQUIDITY = 72138073;

    function run() external {
        vm.startBroadcast();

        IVault(VAULT).removeLiquidityAndWithdraw(POSITION_ID, LIQUIDITY);

        vm.stopBroadcast();

        console.log("Liquidity removed!");
        console.log("  Position ID:", POSITION_ID);
        console.log("  USDC and USDT sent back to your wallet (unwrapped from Aave)");
    }
}
