# Yield-Enhanced Swap: USDe/sUSDe via Aave + Uniswap

> Hackathon project — Uniswap API Track

## TL;DR

Users swap **USDe <> sUSDe** through a simple interface (script/CLI).
Under the hood, tokens are deposited into **Aave v3** and the actual **Uniswap v3 pool** holds **StaticAToken (non-rebasing) versions** of USDe and sUSDe.
Liquidity providers earn **Uniswap swap fees + Aave lending yield + Aave incentive rewards**.

```
User deposits USDe or sUSDe
        │
        ▼
┌──────────────────────┐
│   Vault Contract      │  Wraps tokens: USDe → Aave → staticAToken (waUSDe)
│   (our Solidity code) │  Same for sUSDe → wasUSDe
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Uniswap v3 Pool      │  Pool pair: waUSDe / wasUSDe
│  (standard v3 pool)   │  Fees go to LPs as usual
└──────────┬───────────┘
           │
           ▼
   Aave yield accrues inside staticATokens (value goes up, not balance)
   Aave incentive rewards → claimed by Vault → distributed to LPs
```

---

## Architecture Decisions (already made)

| Decision | Choice | Why |
|---|---|---|
| Rebasing problem | Use **Aave StaticATokenLM** (ERC-4626 wrapped aTokens) | aTokens rebase (balance increases over time), which breaks Uniswap pool math. StaticATokens are non-rebasing: their *value* increases instead. This is Aave's official solution. |
| Uniswap version | **v3** (not v4) | v3 is battle-tested, well-documented, deployed on Sepolia. Easier to debug under time pressure. |
| User interface | **CLI / scripts only** | Rules say UI is not required. Don't waste time on frontend. |
| Yield narrative | Frame as **"yield-enhanced LP"** | The swap pair (USDe/sUSDe) won't have huge volume. The real product is that LPs earn more than on a standard pool. |
| Target chain | **Sepolia testnet** + at least 1 small **mainnet tx** | Need tx IDs for submission. Sepolia for dev, mainnet for credibility. |

---

## What You Need to Build

### Contract 1: `Vault.sol` — The wrapper/router

This is the **core contract** your team writes. It sits between users and the Uniswap pool.

**Functions it must have:**

```solidity
// --- LP functions ---
depositAndAddLiquidity(address token, uint256 amount, int24 tickLower, int24 tickUpper)
// 1. Takes USDe or sUSDe from user
// 2. Deposits into Aave's StaticATokenLM wrapper (ERC-4626 deposit)
// 3. Adds the staticAToken as liquidity to the Uniswap v3 pool
// 4. Tracks the user's LP share (store the NFT position ID)

removeLiquidityAndWithdraw(uint256 positionId)
// 1. Removes liquidity from Uniswap pool (gets back staticATokens)
// 2. Redeems staticATokens from Aave (gets back USDe/sUSDe)
// 3. Returns underlying tokens to user

// --- Swap functions ---
swap(address tokenIn, uint256 amountIn, uint256 amountOutMin)
// 1. Takes USDe or sUSDe from user
// 2. Wraps into staticAToken
// 3. Swaps on Uniswap v3 pool (waUSDe <> wasUSDe)
// 4. Unwraps output staticAToken back to underlying
// 5. Sends output token to user

// --- Reward functions ---
claimRewards()
// Claims Aave incentive rewards from StaticATokenLM
// Distributes to LPs proportionally
```

### Contract 2: Not needed — use existing deployments

- **StaticATokenLM**: Already deployed by Aave. Find addresses in [`bgd-labs/aave-address-book`](https://github.com/bgd-labs/aave-address-book)
- **Uniswap v3 Factory + NonfungiblePositionManager**: Already deployed. Use standard addresses.

---

## Step-by-Step Implementation Plan

### Step 0: Setup (30 min)

```bash
# Init a Foundry project
forge init yield-enhanced-swap
cd yield-enhanced-swap

# Install dependencies
forge install aave/aave-v3-core
forge install Uniswap/v3-core
forge install Uniswap/v3-periphery
forge install OpenZeppelin/openzeppelin-contracts

# Get a Uniswap API key
# Go to https://developers.uniswap.org → sign up → create project → copy API key

# Set up .env
cp .env.example .env
# Fill in: PRIVATE_KEY, RPC_URL (Sepolia alchemy/infura), UNISWAP_API_KEY, ETHERSCAN_API_KEY
```

### Step 1: Check if USDe/sUSDe are on Aave Sepolia (1 hour)

**This is the first thing to verify.** USDe and sUSDe are on Aave v3 Ethereum mainnet, but might NOT be on Sepolia testnet.

**If they ARE on Sepolia:**
- Great, find the StaticATokenLM addresses in `aave-address-book` and use them.

**If they are NOT on Sepolia (most likely):**
- **Option A (recommended for hackathon):** Deploy 2 mock ERC-20 tokens on Sepolia ("MockUSDe" and "MocksUSDe"). Then deploy mock StaticAToken wrappers (simple ERC-4626 vaults that simulate yield). This lets you demo the full flow.
- **Option B:** Work directly on mainnet with small amounts ($5-10 worth). More impressive but costs real money and is riskier.
- **Option C:** Use a local Ethereum mainnet fork (`anvil --fork-url <mainnet-rpc>`). Good for development but you can't show real tx IDs.

**Recommended approach:** Develop on a local mainnet fork (Option C), then deploy mocks on Sepolia for tx IDs (Option A), then do 1 small mainnet tx (Option B) for the submission.

### Step 2: Write `Vault.sol` (3-4 hours)

This is the main work. Key interfaces you'll interact with:

```solidity
// Aave StaticATokenLM (ERC-4626 standard)
interface IStaticATokenLM {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function claimRewards(address receiver) external; // claims Aave incentives
}

// Uniswap v3 NonfungiblePositionManager
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external returns (uint256 amount0, uint256 amount1);
}
```

**Implementation order:**
1. Write the swap function first (simplest, most demonstrable)
2. Then LP deposit/withdraw
3. Then reward claiming (nice-to-have, can be manual)

### Step 3: Create the Uniswap Pool (1 hour)

Write a deployment script that:

```solidity
// In a Foundry script
INonfungiblePositionManager positionManager = INonfungiblePositionManager(POSITION_MANAGER_ADDRESS);

// This creates the pool AND sets initial price in one call
positionManager.createAndInitializePoolIfNecessary(
    waUSDe,           // token0 (sort addresses!)
    wasUSDe,          // token1
    3000,             // 0.3% fee tier (good for correlated pairs, could also use 500 for 0.05%)
    sqrtPriceX96      // initial price — calculate based on USDe/sUSDe exchange rate
);
```

**Important:** token0 must be the lower address. Sort them!

**Fee tier choice:** Since USDe/sUSDe are correlated (both USD-denominated), use either:
- `500` (0.05%) — tightest spread, good for stablecoin-like pairs
- `3000` (0.3%) — more fees per swap for LPs

### Step 4: Integrate Uniswap API for Routing (2 hours)

Write a script (TypeScript/Python) that uses the Uniswap API to route swaps:

```typescript
// scripts/swap.ts
const UNISWAP_API = "https://api.uniswap.org";
const API_KEY = process.env.UNISWAP_API_KEY;

// 1. Check approval
const approvalResp = await fetch(`${UNISWAP_API}/v1/check-approval`, {
    method: "POST",
    headers: { "x-api-key": API_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({
        token: USDe_ADDRESS,
        amount: amountIn,
        walletAddress: userAddress,
        chainId: 1 // or 11155111 for Sepolia
    })
});

// 2. Get quote
const quoteResp = await fetch(`${UNISWAP_API}/v2/quote`, {
    method: "POST",
    headers: { "x-api-key": API_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({
        tokenIn: USDe_ADDRESS,
        tokenInChainId: 1,
        tokenOut: sUSDe_ADDRESS,
        tokenOutChainId: 1,
        amount: amountIn,
        type: "EXACT_INPUT",
        slippageTolerance: 0.5
    })
});

// 3. Execute swap — the API returns tx calldata, submit it onchain
const swapResp = await fetch(`${UNISWAP_API}/v2/swap`, { ... });
const { to, data, value } = await swapResp.json();
const tx = await wallet.sendTransaction({ to, data, value });
console.log("Swap TX:", tx.hash); // ← THIS IS YOUR SUBMISSION TX ID
```

**Note:** The Uniswap API routing may not find your custom pool on Sepolia. In that case:
- Use the API for mainnet demo (even a tiny swap)
- For Sepolia, interact with the pool directly via the SwapRouter contract

### Step 5: Write Demo Script (1-2 hours)

Create `scripts/demo.sh` or `scripts/demo.ts` that runs the full flow:

```
1. Deploy Vault contract (or use already-deployed address)
2. User A deposits 100 USDe → becomes LP
3. User B swaps 10 USDe → sUSDe through the Vault
4. Show that User A's position now has swap fees
5. User A withdraws → gets back more than they deposited (fees + Aave yield)
6. Print all transaction IDs
```

### Step 6: Submission Checklist (1 hour)

- [ ] Public GitHub repo with all code
- [ ] This README updated with actual deployed addresses and tx IDs
- [ ] At least 3-5 transaction IDs (deploy, deposit, swap, withdraw, claim)
- [ ] Demo video recorded (max 3 minutes) — screen record the demo script running
- [ ] Fill out Uniswap Developer Feedback Form: https://developers.uniswap.org/feedback
- [ ] Code is clean enough to read (not perfect, just not embarrassing)

---

## Key Addresses You'll Need

### Ethereum Mainnet
| Contract | Address |
|---|---|
| USDe | `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3` |
| sUSDe | `0x9D39A5DE30e57443BfF2A8307A4256c8797A3497` |
| Uniswap v3 Factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| Uniswap v3 NonfungiblePositionManager | `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` |
| Uniswap v3 SwapRouter02 | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |
| Aave v3 Pool (Ethereum) | Check `aave-address-book` for latest |
| StaticATokenLM for USDe | Check `aave-address-book` — look for `stataUSDe` |
| StaticATokenLM for sUSDe | Check `aave-address-book` — look for `statasUSDe` |

### Sepolia
| Contract | Address |
|---|---|
| Uniswap v3 Factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| Uniswap v3 NonfungiblePositionManager | `0x1238536071E1c677A632429e3655c799b22cDA52` |
| MockUSDe | *deploy yourself* |
| MocksUSDe | *deploy yourself* |

> **TODO for team:** Verify all addresses before using. These may have changed.

---

## Tech Stack

- **Solidity** — Vault contract (use Solidity 0.8.20+)
- **Foundry** — compile, test, deploy (`forge`, `cast`, `anvil`)
- **TypeScript** — scripts for Uniswap API integration
- **ethers.js v6** or **viem** — for tx submission
- **Aave v3 StaticATokenLM** — non-rebasing aToken wrapper
- **Uniswap v3** — AMM pool + position manager

---

## How to Dev (Local Mainnet Fork)

```bash
# Terminal 1: start local fork
anvil --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY --chain-id 31337

# Terminal 2: deploy and test
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# Impersonate a whale to get USDe for testing
cast send --rpc-url http://localhost:8545 \
  --unlocked --from 0xSOME_USDE_WHALE \
  0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 \
  "transfer(address,uint256)" YOUR_ADDRESS 1000000000000000000000
```

---

## Potential Pitfalls

1. **token0/token1 ordering** — Uniswap requires token0 < token1 (by address). Sort them or the pool creation reverts.
2. **Approval dance** — Every step needs token approvals: user→Vault, Vault→StaticAToken, Vault→PositionManager. Don't forget any.
3. **sqrtPriceX96 calculation** — Use `encodeSqrtRatioX96` from the Uniswap SDK, or calculate manually: `sqrt(price) * 2^96`. For a 1:1 pair, it's `79228162514264337593543950336`.
4. **Tick spacing** — Different fee tiers have different tick spacings. For 0.05% fee: spacing=10. For 0.3%: spacing=60. Your tickLower/tickUpper must be multiples of the spacing.
5. **StaticAToken might not exist for USDe/sUSDe on testnet** — See Step 1 above for workarounds.

---

## What "Done" Looks Like

A successful submission has:
1. A Vault contract deployed on Sepolia (and optionally mainnet)
2. A Uniswap v3 pool of waUSDe/wasUSDe with liquidity
3. At least one swap going through the Vault (USDe in → sUSDe out)
4. Transaction IDs for all of the above
5. A 3-min video showing the scripts running and explaining the architecture
6. The Uniswap API key used for at least the routing/quoting part

The Aave reward claiming is a **nice-to-have** — get the core swap + LP flow working first.

---

## Priority Order (if running low on time)

1. **Swap flow** via Vault (deposit → wrap → swap → unwrap → withdraw) — this is the minimum viable demo
2. **LP flow** (deposit → wrap → add liquidity → remove → unwrap) — shows the full value prop
3. **Uniswap API integration** for routing — required by hackathon rules
4. **Reward claiming** from Aave — cherry on top
5. **Mainnet tx** — one small swap for credibility
