/**
 * Uniswap API Integration — Yield-Enhanced Swap
 *
 * This script demonstrates the Uniswap Trading API (trade-api.gateway.uniswap.org)
 * integrated with the YieldHook project:
 *
 *   1. GET pool info for the stataUSDC/stataUSDT v4 pool via /lp/pool_info
 *   2. GET a swap quote for USDC -> USDT on Base Sepolia via /quote
 *   3. EXECUTE a swap on Base Sepolia via /swap + ethers wallet
 *
 * The API handles routing and calldata generation.
 * The YieldHook contract (deployed separately) handles the Aave wrap/unwrap layer.
 *
 * Usage:
 *   npx tsx scripts/uniswap-api.ts
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

const CHAIN_ID = 84532; // Base Sepolia

// Base Sepolia token addresses
const USDC       = "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f";
const USDT       = "0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a";
const STATA_USDC = "0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a";
const STATA_USDT = "0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F";

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

// ─── Step 1: Pool info ────────────────────────────────────────────────────────

async function getPoolInfo() {
  console.log("\n[1/3] Fetching pool info via /lp/pool_info...");

  try {
    const data = await apiPost("/lp/pool_info", {
      protocol:  "V4",
      chainId:   CHAIN_ID,
      poolId:    YIELD_HOOK, // V4 pools are identified by hook + key, use hook address
    });
    console.log("Pool info response:", JSON.stringify(data, null, 2));
    return data;
  } catch (err: any) {
    // Pool may not be indexed yet if just deployed — fall back to static info
    console.log("Pool info not available yet (pool may not be indexed):", err.message);
    console.log("Pool details (from deployment):");
    console.log("  Protocol:  Uniswap v4");
    console.log("  Chain:     Base Sepolia (84532)");
    console.log("  currency0: stataUSDC", STATA_USDC);
    console.log("  currency1: stataUSDT", STATA_USDT);
    console.log("  Fee:       0.05% (500)");
    console.log("  Hook:     ", YIELD_HOOK || "(not yet deployed)");
    return null;
  }
}

// ─── Step 2: Quote ────────────────────────────────────────────────────────────

async function getQuote(walletAddress: string) {
  console.log("\n[2/3] Getting swap quote via /quote...");
  console.log(`  Swapping ${Number(SWAP_AMOUNT) / 1e6} USDC -> USDT on Base Sepolia`);

  const body = {
    tokenIn:        USDC,
    tokenInChainId: CHAIN_ID,
    tokenOut:       USDT,
    tokenOutChainId: CHAIN_ID,
    amount:         SWAP_AMOUNT,
    type:           "EXACT_INPUT",
    swapper:        walletAddress,
    slippageTolerance: 0.5,
    protocols:      ["V2", "V3", "V4"],
    urgency:        "normal",
  };

  const data = await apiPost("/quote", body);

  const quote = data.quote;
  const output = quote?.output?.amount ?? quote?.output;
  const route  = quote?.routeString ?? quote?.route ?? "N/A";
  const gasFee = quote?.gasFeeUSD ?? "N/A";

  console.log("Quote received:");
  console.log(`  Input:     ${Number(SWAP_AMOUNT) / 1e6} USDC`);
  console.log(`  Output:    ${Number(output) / 1e6} USDT`);
  console.log(`  Route:     ${typeof route === "string" ? route : JSON.stringify(route)}`);
  console.log(`  Gas (USD): $${gasFee}`);
  console.log(`  Routing:   ${data.routing}`);

  return data;
}

// ─── Step 3: Execute swap ─────────────────────────────────────────────────────

async function executeSwap(quoteData: any, wallet: ethers.Wallet) {
  console.log("\n[3/3] Executing swap via /swap...");

  // Build the swap transaction from the quote
  const swapBody: any = {
    quote:              quoteData.quote,
    signature:          null,
    simulateTransaction: false,
  };
  if (quoteData.permitData) {
    swapBody.permitData = quoteData.permitData;
  }

  const swapData = await apiPost("/swap", swapBody);
  const tx = swapData.swap;

  console.log("Swap transaction built:");
  console.log("  to:       ", tx.to);
  console.log("  value:    ", tx.value ?? "0");
  console.log("  gasLimit: ", tx.gasLimit);

  // Check if approval is needed first
  console.log("\nChecking token approval...");
  try {
    const approvalData = await apiPost("/check_approval", {
      token:         USDC,
      amount:        SWAP_AMOUNT,
      walletAddress: wallet.address,
      chainId:       CHAIN_ID,
    });

    if (approvalData.approval) {
      console.log("Approval required — sending approval tx...");
      const approveTx = await wallet.sendTransaction({
        to:   approvalData.approval.to,
        data: approvalData.approval.data,
      });
      await approveTx.wait();
      console.log("Approval tx:", approveTx.hash);
    } else {
      console.log("No approval needed.");
    }
  } catch (err: any) {
    console.log("Approval check skipped:", err.message);
  }

  // Send the swap transaction
  console.log("\nSending swap transaction...");
  const sentTx = await wallet.sendTransaction({
    to:       tx.to,
    data:     tx.data,
    value:    tx.value ? BigInt(tx.value) : 0n,
    gasLimit: tx.gasLimit ? BigInt(tx.gasLimit) : undefined,
  });

  console.log("Swap tx submitted:", sentTx.hash);
  console.log(`  https://sepolia.basescan.org/tx/${sentTx.hash}`);

  const receipt = await sentTx.wait();
  console.log("Swap confirmed in block:", receipt?.blockNumber);
  return sentTx.hash;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  requireEnv();

  console.log("Yield-Enhanced Swap — Uniswap API Demo");
  console.log("Chain: Base Sepolia (84532)");
  console.log("API:  ", API_BASE);

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("\nWallet:", wallet.address);
  const balance = await provider.getBalance(wallet.address);
  console.log("ETH balance:", ethers.formatEther(balance));

  // Step 1: Pool info
  await getPoolInfo();

  // Step 2: Quote
  const quoteData = await getQuote(wallet.address);

  // Step 3: Execute (comment out to do a dry-run)
  if (process.argv.includes("--execute")) {
    await executeSwap(quoteData, wallet);
  } else {
    console.log("\nDry-run complete. Pass --execute to submit the swap transaction.");
    console.log("Example: npx tsx scripts/uniswap-api.ts --execute");
  }

  console.log("\nDone.");
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
