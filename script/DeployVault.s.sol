// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "../lib/forge-std/src/Script.sol";
import {Vault} from "../src/Vault.sol";

/// @notice Deploys the Vault on Base Sepolia using real Aave v3 stata tokens for USDC/USDT.
///         The Vault variable names internally say "USDe/sUSDe" but the logic is identical —
///         it works with any ERC-20 + ERC-4626 (StaticATokenLM) pair.
///
///         Mapping for Base Sepolia:
///           usde   → USDC  (0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f)
///           susde  → USDT  (0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a)
///           waUSDe → stataUSDC (0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a)
///           wasUSDe→ stataUSDT (0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F)
contract DeployVault is Script {
    // ── Underlying tokens (Base Sepolia) ────────────────────────────────────
    address constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant USDT = 0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a;

    // ── Aave v3 StaticATokenLM wrappers (Base Sepolia) ───────────────────────
    address constant STATA_USDC = 0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a;
    address constant STATA_USDT = 0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F;

    // ── Uniswap v3 (Base Sepolia) ────────────────────────────────────────────
    address constant POSITION_MANAGER = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;
    address constant SWAP_ROUTER = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;

    // ── Pool config ──────────────────────────────────────────────────────────
    uint24 constant POOL_FEE = 500; // 0.05% — best for correlated stablecoin pairs

    function run() external {
        vm.startBroadcast();

        Vault vault = new Vault(
            USDC,             // usde   → USDC
            USDT,             // susde  → USDT
            STATA_USDC,       // waUSDe → stataUSDC
            STATA_USDT,       // wasUSDe→ stataUSDT
            POSITION_MANAGER,
            SWAP_ROUTER,
            POOL_FEE
        );

        vm.stopBroadcast();

        console.log("Vault deployed at:", address(vault));
        console.log("  USDC:          ", USDC);
        console.log("  USDT:          ", USDT);
        console.log("  stataUSDC:     ", STATA_USDC);
        console.log("  stataUSDT:     ", STATA_USDT);
        console.log("  Pool fee:       0.05% (500)");
        console.log("  Pool address:   0xe59cF48E3Cd4dBc234519d4222861D0573cB3054");
    }
}
