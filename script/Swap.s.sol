// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "../lib/forge-std/src/Script.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IVault {
    function swap(address tokenIn, uint256 amountIn, uint256 amountOutMin) external returns (uint256 amountOut);
}

contract Swap is Script {
    // ── Base Sepolia addresses ───────────────────────────────────────────────
    address constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant USDT = 0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a;
    address constant VAULT = 0x526dAE03f78C6295D2DB92f20268abB509F88095;

    // ── Swap 10 USDC → USDT (6 decimals) ────────────────────────────────────
    uint256 constant AMOUNT_IN = 10 * 1e6;   // 10 USDC
    uint256 constant AMOUNT_OUT_MIN = 0;      // no slippage protection for demo

    function run() external {
        vm.startBroadcast();

        // Step 1: Approve Vault to spend USDC
        IERC20(USDC).approve(VAULT, AMOUNT_IN);

        // Step 2: Swap USDC → USDT through the Vault
        // Under the hood: USDC → stataUSDC (Aave) → stataUSDT (Uniswap) → USDT (Aave)
        uint256 amountOut = IVault(VAULT).swap(USDC, AMOUNT_IN, AMOUNT_OUT_MIN);

        vm.stopBroadcast();

        console.log("Swap successful!");
        console.log("  Sent:     10 USDC");
        console.log("  Received:", amountOut);
        console.log("  (divide by 1e6 for USDT amount)");
    }
}
