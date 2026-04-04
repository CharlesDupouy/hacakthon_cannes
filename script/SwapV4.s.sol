// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldHook} from "../src/YieldHook.sol";

/// @notice Swaps 10 USDC → USDT through the YieldHook on Base Sepolia.
///
/// HOW TO RUN:
///   source .env
///   forge script script/SwapV4.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract SwapV4 is Script {
    address constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant USDT = 0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a;

    uint256 constant AMOUNT_IN      = 10 * 1e6; // 10 USDC (6 decimals)
    uint256 constant AMOUNT_OUT_MIN = 0;         // no slippage protection for demo

    function run() external {
        address hookAddress = vm.envAddress("YIELD_HOOK_ADDRESS");
        require(hookAddress != address(0), "Set YIELD_HOOK_ADDRESS in .env");

        vm.startBroadcast();

        // Approve the hook to pull USDC from caller
        IERC20(USDC).approve(hookAddress, AMOUNT_IN);

        // Swap: USDC → wrap to stataUSDC → swap pool → stataUSDT → unwrap → USDT
        uint256 amountOut = YieldHook(hookAddress).swap(USDC, AMOUNT_IN, AMOUNT_OUT_MIN);

        vm.stopBroadcast();

        console.log("-- YieldHook v4 Swap --");
        console.log("Sent:     10 USDC");
        console.log("Received: ", amountOut, "(raw, divide by 1e6 for USDT)");
    }
}
