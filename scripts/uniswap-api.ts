/**
 * Uniswap API Integration — Yield-Enhanced Swap
 *
 * This script demonstrates the Uniswap Trading API (trade-api.gateway.uniswap.org):
 *
 *   1. GET a USDC -> USDT quote on Ethereum mainnet via /quote
 *      (Mainnet is used for quoting because Base Sepolia test tokens are not
 *       indexed by the API. The quote shows the API's routing capabilities.)
 *   2. EXECUTE a yield-enhanced swap on Base Sepolia via our YieldHook contract
 *      (The hook wraps USDC -> Aave -> stataUSDC, swaps on v4, unwraps back)
 *
 * The Uniswap API handles optimal routing and calldata generation on mainnet.
 * The YieldHook contract handles the Aave wrap/unwrap layer on testnet.
 *
 * Usage:
 *   npx tsx scripts/uniswap-api.ts          # dry run (no tx)
 *   npx tsx scripts/uniswap-api.ts --execute # execute testnet swap
 *
 * Required env vars (.env in project root):
 *   UNISWAP_API_KEY       — from developers.uniswap.org
 *   PRIVATE_KEY           — wallet private key (0x...)
 *   BASE_SEPOLIA_RPC_URL  — e.g. https://base-sepolia.g.alchemy.com/v2/...
 *   YIELD_HOOK_ADDRESS    — deployed YieldHook contract address
 */

import * as dotenv from "dotenv";
import { ethers } from "ethers";
import * as path from "path";

dotenv.config({ path: path.resolve(__dirname, "../.env") });

// ─── Config ───────────────────────────────────────────────────────────────────

const API_BASE = "https://trade-api.gateway.uniswap.org/v1";
const API_KEY  = process.env.UNISWAP_API_KEY!;
const RPC_URL  = process.env.BASE_SEPOLIA_RPC_URL!;
const PRIVATE_KEY = process.env.PRIVATE_KEY!;
const YIELD_HOOK  = process.env.YIELD_HOOK_ADDRESS!;

// Base Sepolia (our YieldHook deployment)
const CHAIN_ID_TESTNET = 84532;
const USDC_TESTNET     = "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f";
const USDT_TESTNET     = "0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a";

// Ethereum mainnet (for Uniswap API quote demo)
const CHAIN_ID_MAINNET = 1;
const USDC_MAINNET     = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDT_MAINNET     = "0xdAC17F958D2ee523a2206206994597C13D831ec7";

const SWAP_AMOUNT = "10000000"; // 10 USDC (6 decimals)

// ─── Helpers ──────────────────────────────────────────────────────────────────

function requireEnv() {
  const missing = ["UNISWAP_API_KEY", "BASE_SEPOLIA_RPC_URL", "PRIVATE_KEY"]
    .filter((k) => !process.env[k]);
  if (missing.length > 0) {
    console.error("Missing env vars:", missing.join(", "));
    console.error("Copy .env.example to .env and fill in the values.");
    process.exit(1);
  }
}

async function apiPost(path: string, body: object): Promise<any> {
  const res = await fetch(`${API_BASE}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": API_KEY,
    },
    body: JSON.stringify(body),
  });

  const text = await res.text();
  if (!res.ok) {
    throw new Error(`API ${path} failed (${res.status}): ${text}`);
  }
  return JSON.parse(text);
}

// ─── Step 1: Quote via Uniswap API (Ethereum mainnet) ────────────────────────
// Base Sepolia test tokens are not indexed by the Uniswap API.
// We quote the same trade on mainnet to demonstrate the API, then execute
// the yield-enhanced version on our testnet hook.

async function getMainnetQuote(walletAddress: string) {
  console.log("\n[1/2] Getting USDC -> USDT quote via Uniswap API (Ethereum mainnet)...");
  console.log(`  Amount: ${Number(SWAP_AMOUNT) / 1e6} USDC`);
  console.log("  Note: quoting on mainnet because Base Sepolia test tokens are not indexed.");

  const body = {
    tokenIn:         USDC_MAINNET,
    tokenInChainId:  CHAIN_ID_MAINNET,
    tokenOut:        USDT_MAINNET,
    tokenOutChainId: CHAIN_ID_MAINNET,
    amount:          SWAP_AMOUNT,
    type:            "EXACT_INPUT",
    swapper:         walletAddress,
    slippageTolerance: 0.5,
    protocols:       ["V2", "V3", "V4"],
    urgency:         "normal",
  };

  const data = await apiPost("/quote", body);

  const quote  = data.quote;
  const output = quote?.output?.amount ?? quote?.output;
  const route  = quote?.routeString ?? quote?.route ?? "N/A";
  const gasFee = quote?.gasFeeUSD ?? "N/A";

  console.log("\nQuote received (mainnet reference):");
  console.log(`  Input:     ${Number(SWAP_AMOUNT) / 1e6} USDC`);
  console.log(`  Output:    ${(Number(output) / 1e6).toFixed(6)} USDT`);
  console.log(`  Route:     ${typeof route === "string" ? route : JSON.stringify(route)}`);
  console.log(`  Gas (USD): $${gasFee}`);
  console.log(`  Routing:   ${data.routing}`);
  console.log("\n  -> On our YieldHook, this same swap also earns Aave lending yield for LPs.");

  return data;
}

// ─── Step 2: Execute yield-enhanced swap on Base Sepolia via YieldHook ────────

const YIELD_HOOK_ABI = [
  "function swap(address tokenIn, uint256 amountIn, uint256 amountOutMin) external returns (uint256)",
];
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address) external view returns (uint256)",
];

async function executeTestnetSwap(wallet: ethers.Wallet) {
  console.log("\n[2/2] Executing yield-enhanced swap on Base Sepolia via YieldHook...");
  console.log(`  Contract: ${YIELD_HOOK}`);
  console.log(`  Swap: 10 USDC -> USDT (USDC -> Aave -> stataUSDC -> pool -> stataUSDT -> Aave -> USDT)`);

  const hook  = new ethers.Contract(YIELD_HOOK, YIELD_HOOK_ABI, wallet);
  const usdc  = new ethers.Contract(USDC_TESTNET, ERC20_ABI, wallet);

  const balBefore = await (new ethers.Contract(USDT_TESTNET, ERC20_ABI, wallet)).balanceOf(wallet.address);

  console.log("\nApproving USDC...");
  const approveTx = await usdc.approve(YIELD_HOOK, BigInt(SWAP_AMOUNT));
  await approveTx.wait();
  console.log("  Approved.");

  console.log("Calling hook.swap()...");
  const swapTx = await hook.swap(USDC_TESTNET, BigInt(SWAP_AMOUNT), 0n);
  const receipt = await swapTx.wait();
  console.log("Swap confirmed in block:", receipt?.blockNumber);
  console.log(`  https://sepolia.basescan.org/tx/${swapTx.hash}`);

  const balAfter = await (new ethers.Contract(USDT_TESTNET, ERC20_ABI, wallet)).balanceOf(wallet.address);
  const usdtOut  = balAfter - balBefore;
  console.log(`\nResult: 10 USDC -> ${(Number(usdtOut) / 1e6).toFixed(6)} USDT`);
  console.log("  (LPs in this pool earned Aave yield + swap fees on this trade)");
  return swapTx.hash;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  requireEnv();

  console.log("Yield-Enhanced Swap — Uniswap API Demo");
  console.log("API:", API_BASE);

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("\nWallet:", wallet.address);
  const balance = await provider.getBalance(wallet.address);
  console.log("ETH balance (Base Sepolia):", ethers.formatEther(balance));

  // Step 1: Get a USDC -> USDT quote from the Uniswap Trading API (mainnet)
  await getMainnetQuote(wallet.address);

  // Step 2: Execute the yield-enhanced swap on our testnet hook
  if (process.argv.includes("--execute")) {
    if (!YIELD_HOOK) {
      console.error("\nSet YIELD_HOOK_ADDRESS in .env to execute the testnet swap.");
      process.exit(1);
    }
    await executeTestnetSwap(wallet);
  } else {
    console.log("\nDry-run complete.");
    console.log("Pass --execute to also submit the testnet swap transaction:");
    console.log("  npx tsx uniswap-api.ts --execute");
  }

  console.log("\nDone.");
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
