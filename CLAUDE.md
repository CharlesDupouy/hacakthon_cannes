# Yield-Enhanced Swap — Full Project Context for Claude

You are helping build a hackathon project for the **Uniswap API track**. Read this entire file before writing any code.

---

## Current State (read this first)

The project is **partially complete**. Here is exactly what has been done and what remains:

### Done ✅
- Vault.sol written and deployed on Base Sepolia
- Uniswap v3 pool deployed on Base Sepolia (stataUSDC/stataUSDT)
- Liquidity added to the pool
- Full swap tested and working: USDC → Aave → Uniswap → Aave → USDT
- removeLiquidityAndWithdraw tested and working
- claimRewards tested and working

### Still needed ❌
- **Uniswap API TypeScript script** — required by hackathon rules (use `scripts/uniswap-api.ts`)
- **README.md** updated with real deployed addresses and tx IDs
- **Demo video** (3 minutes max)

---

## Project Goal

Build a system where users can **swap USDC <> USDT** (testnet) or **USDe <> sUSDe** (mainnet) but the underlying Uniswap pool holds **Aave StaticAToken (stata) wrapped versions**. LPs earn Uniswap swap fees + Aave lending yield simultaneously.

### Testnet vs Mainnet Strategy
- **Base Sepolia testnet**: uses real USDC/USDT + real Aave v3 StaticATokenLM (no mocks needed — Aave v3 is live on Base Sepolia)
- **Ethereum Mainnet** (future): same Vault code, swap addresses to USDe/sUSDe + their Aave stata wrappers

---

## Deployed Contracts (Base Sepolia, chain ID 84532)

### Our contracts
| Contract | Address |
|---|---|
| Vault | `0x526dAE03f78C6295D2DB92f20268abB509F88095` |
| Uniswap v3 Pool (stataUSDC/stataUSDT, 0.05%) | `0xe59cF48E3Cd4dBc234519d4222861D0573cB3054` |

### Real Aave v3 on Base Sepolia
| Contract | Address |
|---|---|
| USDC (TestnetERC20) | `0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f` |
| USDT (TestnetERC20) | `0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a` |
| stataUSDC (StaticATokenLM) | `0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a` |
| stataUSDT (StaticATokenLM) | `0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F` |
| Aave v3 Pool | `0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27` |
| Aave Faucet | `0xD9145b5F45Ad4519c7acCd6e0A4A82E83bB8A6Dc` |

### Uniswap v3 on Base Sepolia
| Contract | Address |
|---|---|
| Factory | `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24` |
| NonfungiblePositionManager | `0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2` |
| SwapRouter02 | `0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4` |

---

## Wallet

Deployer address: `0xb9dfAC9688A2dE1F882d9e78495a40618576303d`

To get test USDC/USDT (only way — they are Aave test tokens, not buyable):
```bash
cast send 0xD9145b5F45Ad4519c7acCd6e0A4A82E83bB8A6Dc "mint(address,address,uint256)" \
  0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f \
  YOUR_ADDRESS 10000000000 \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```
(repeat with USDT address for USDT)

---

## Architecture

```
User sends USDC or USDT
        │
        ▼
┌──────────────────────────────────┐
│          Vault.sol               │
│  (0x526dAE03f78C6295D2DB92...)   │
│                                  │
│  swap():                         │
│  1. Pull USDC from user          │
│  2. Deposit USDC → Aave          │
│     → get stataUSDC (ERC-4626)   │
│  3. Swap stataUSDC → stataUSDT   │
│     on Uniswap v3 pool           │
│  4. Redeem stataUSDT → USDT      │
│  5. Send USDT to user            │
└──────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────┐
│   Uniswap v3 Pool                │
│   stataUSDC / stataUSDT          │
│   Fee: 0.05% (500)               │
│   (0xe59cF48E3Cd4dBc234...)      │
└──────────────────────────────────┘
        │
        ▼
   Aave yield accrues inside stata tokens
   (share price increases over time)
```

---

## Critical Bugs Already Fixed (do not reintroduce)

### 1. SwapRouter02 interface — NO deadline in params
SwapRouter02 on Base Sepolia does NOT have `deadline` in `ExactInputSingleParams`. Using it causes `unrecognized function selector` revert.

**Wrong (SwapRouter v1):**
```solidity
struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 deadline;  // ← DO NOT ADD THIS for SwapRouter02
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
}
```

**Correct (SwapRouter02):**
```solidity
struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
}
```

### 2. StaticATokenLM claimRewards signature
The real Aave `StataTokenV2.claimRewards` takes a second argument `address[] calldata rewards`:
```solidity
// WRONG:
waUSDe.claimRewards(owner);

// CORRECT:
waUSDe.claimRewards(owner, new address[](0));
```

### 3. Vault naming (cosmetic — do not change)
The Vault variables are named `usde`, `susde`, `waUSDe`, `wasUSDe` internally but they hold USDC/USDT on testnet. This is intentional — the logic is identical, only the constructor addresses differ. Do not rename.

---

## Pool Price Note

The pool was initialized at 1:1 (stataUSDC:stataUSDT) but stataUSDC has a higher Aave liquidityIndex (~1.24) than stataUSDT (~1.0). This means swaps give slightly worse rates than expected. This is a testnet initialization detail — acceptable for the hackathon demo.

---

## Scripts

All scripts are in `script/`. Run with:
```bash
source .env
forge script script/SCRIPT_NAME.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

| Script | What it does |
|---|---|
| `DeployMocks.s.sol` | Creates the Uniswap v3 pool (already done, don't run again) |
| `DeployVault.s.sol` | Deploys the Vault (already done, don't run again) |
| `AddLiquidity.s.sol` | Adds 100 USDC + 100 USDT liquidity via Vault |
| `Swap.s.sol` | Swaps 10 USDC → USDT via Vault |
| `RemoveLiquidity.s.sol` | Removes liquidity from a position (update POSITION_ID and LIQUIDITY before running) |
| `ClaimRewards.s.sol` | Claims Aave rewards (owner only, testnet has no rewards) |

---

## What Remains: Uniswap API Script

The hackathon **requires** use of the Uniswap API with an API key from developers.uniswap.org.

Write `scripts/uniswap-api.ts` that:
1. Gets a **quote** from the Uniswap API for swapping USDC → USDT
2. Shows the best route found
3. Optionally executes the swap via the API calldata

```typescript
// API base
const UNISWAP_API = "https://api.uniswap.org";
const API_KEY = process.env.UNISWAP_API_KEY;

// Quote endpoint
POST /v2/quote
{
  tokenIn: "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f",  // USDC Base Sepolia
  tokenInChainId: 84532,
  tokenOut: "0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a", // USDT Base Sepolia
  tokenOutChainId: 84532,
  amount: "10000000",  // 10 USDC (6 decimals)
  type: "EXACT_INPUT"
}

// Approval check
POST /v1/check-approval
{
  token: "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f",
  amount: "10000000",
  walletAddress: "0xb9dfAC9688A2dE1F882d9e78495a40618576303d",
  chainId: 84532
}
```

Note: The API may not find a route for our custom pool on Base Sepolia testnet. If it doesn't, use it to quote on mainnet (USDC → USDT on Ethereum) to demonstrate API usage, while the Vault handles the actual testnet execution.

---

## Key Addresses for Ethereum Mainnet (future)

| Contract | Address |
|---|---|
| USDe | `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3` |
| sUSDe | `0x9D39A5DE30e57443BfF2A8307A4256c8797A3497` |
| Uniswap v3 Factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| NonfungiblePositionManager | `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` |
| SwapRouter02 | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |

---

## Hackathon Requirements Checklist

- [x] Vault contract deployed on Base Sepolia
- [x] Uniswap v3 pool created with stata tokens
- [x] Swap executed through the Vault (tx ID exists)
- [x] LP deposit and withdrawal working
- [ ] Uniswap API used with API key
- [ ] README updated with tx IDs and addresses
- [ ] 3-minute demo video recorded
- [ ] Uniswap Developer Feedback Form filled out: https://developers.uniswap.org/feedback

---

## Common Mistakes to Avoid

- Do NOT add `deadline` to SwapRouter02's ExactInputSingleParams
- Do NOT call `claimRewards(address)` with one arg — use `claimRewards(address, address[])`
- Always sort token0/token1 by address (token0 < token1) for Uniswap
- USDC/USDT use **6 decimals** (not 18)
- stataUSDC/stataUSDT use **6 decimals** too
- Tick values must be multiples of tick spacing (10 for 0.05% fee tier)
- After `decreaseLiquidity()` you MUST call `collect()` to actually receive tokens
- The Aave faucet (`0xD9145b...`) is the only way to get test USDC/USDT on Base Sepolia
