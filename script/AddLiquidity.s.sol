// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "../lib/forge-std/src/Script.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IVault {
    function depositAndAddLiquidity(
        uint256 amountUSDe,
        uint256 amountsUSDe,
        int24 tickLower,
        int24 tickUpper
    ) external returns (uint256 tokenId, uint128 liquidity);
}

contract AddLiquidity is Script {
    // ── Base Sepolia addresses ───────────────────────────────────────────────
    address constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant USDT = 0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a;
    address constant VAULT = 0x526dAE03f78C6295D2DB92f20268abB509F88095;

    // ── Amounts: 100 USDC + 100 USDT (6 decimals) ───────────────────────────
    uint256 constant AMOUNT_USDC = 100 * 1e6;
    uint256 constant AMOUNT_USDT = 100 * 1e6;

    // ── Full range ticks for 0.05% fee tier (tick spacing = 10) ─────────────
    int24 constant TICK_LOWER = -887270;
    int24 constant TICK_UPPER = 887270;

    function run() external {
        vm.startBroadcast();

        // Step 1: Approve Vault to spend USDC and USDT
        IERC20(USDC).approve(VAULT, AMOUNT_USDC);
        IERC20(USDT).approve(VAULT, AMOUNT_USDT);

        // Step 2: Deposit and add liquidity
        (uint256 tokenId, uint128 liquidity) = IVault(VAULT).depositAndAddLiquidity(
            AMOUNT_USDC,
            AMOUNT_USDT,
            TICK_LOWER,
            TICK_UPPER
        );

        vm.stopBroadcast();

        console.log("Liquidity added successfully!");
        console.log("  LP Position NFT ID:", tokenId);
        console.log("  Liquidity amount:  ", uint256(liquidity));
        console.log("  USDC deposited:     100");
        console.log("  USDT deposited:     100");
    }
}
