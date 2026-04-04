# Vault.sol — Full Technical Documentation

## Table of Contents

1. [What is the Vault?](#what-is-the-vault)
2. [The Problem it Solves](#the-problem-it-solves)
3. [Architecture Overview](#architecture-overview)
4. [File Structure](#file-structure)
5. [Interfaces](#interfaces)
6. [State Variables](#state-variables)
7. [Constructor — Initialization & Approvals](#constructor)
8. [Function: `swap()`](#function-swap)
9. [Function: `depositAndAddLiquidity()`](#function-depositandaddliquidity)
10. [Function: `removeLiquidityAndWithdraw()`](#function-removeliquidityandwithdraw)
11. [Function: `claimRewards()`](#function-claimrewards)
12. [View Functions](#view-functions)
13. [Internal Helpers](#internal-helpers)
14. [Approval Chain](#approval-chain)
15. [Token Ordering (Critical)](#token-ordering)
16. [Events](#events)
17. [Custom Errors](#custom-errors)
18. [Design Decisions & Tradeoffs](#design-decisions)
19. [Common Pitfalls Avoided](#common-pitfalls-avoided)

---

## What is the Vault?

The `Vault.sol` contract is the **central smart contract** of the Yield-Enhanced Swap project. It acts as an intermediary between users and the DeFi protocols (Aave + Uniswap v3).

From the user's perspective, they simply:
- **Swap** USDe ↔ sUSDe (like any DEX)
- **Provide liquidity** with USDe + sUSDe (like any LP)

But under the hood, the Vault wraps everything into **Aave StaticATokenLM** tokens before touching Uniswap. This gives LPs extra yield from Aave on top of Uniswap swap fees.

```
User sees:    USDe ←→ sUSDe
Pool holds:   waUSDe ←→ wasUSDe  (Aave-wrapped versions, earning yield)
```

---

## The Problem it Solves

### Why not just put USDe/sUSDe directly in a Uniswap pool?

You could, but you'd miss out on Aave lending yield. The trick is using Aave's **aTokens**, which earn interest. But there's a catch:

**aTokens are rebasing** — their balance silently increases over time as yield accrues. If you put rebasing tokens into a Uniswap pool:
- The AMM can't track the extra balance
- This creates **"phantom reserves"** that break pricing
- MEV bots can arbitrage these phantom reserves, stealing the yield

### The Solution: StaticATokenLM (ERC-4626)

Aave provides **StaticATokenLM** wrapper contracts. These implement the **ERC-4626 tokenized vault standard**:
- You deposit USDe → get waUSDe shares
- The **share balance stays constant** (non-rebasing, safe for Uniswap)
- The **share price increases** as yield accrues (1 waUSDe = 1.001 USDe today, 1.002 tomorrow...)
- When you redeem waUSDe → you get back more USDe than you deposited

**Result:** LPs earn **Uniswap swap fees + Aave lending yield** simultaneously.

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────┐
│                         USER                                    │
│                 (holds USDe and/or sUSDe)                       │
└────────┬──────────────────────┬──────────────────┬─────────────┘
         │ swap()               │ depositAndAdd    │ removeLiquidity
         │                      │ Liquidity()      │ AndWithdraw()
         ▼                      ▼                  ▼
┌────────────────────────────────────────────────────────────────┐
│                     VAULT CONTRACT                              │
│                                                                 │
│  1. Accept USDe/sUSDe from users                                │
│  2. Wrap via Aave: USDe → waUSDe, sUSDe → wasUSDe             │
│  3. Interact with Uniswap v3 pool (swap or add liquidity)       │
│  4. Unwrap staticATokens back to USDe/sUSDe on withdrawal      │
│  5. Claim and distribute Aave incentive rewards                 │
└────────┬──────────────────────┬────────────────────────────────┘
         │                      │
         ▼                      ▼
┌──────────────────┐   ┌───────────────────────────────────────┐
│ Aave v3          │   │ Uniswap v3 Pool                        │
│ StaticATokenLM   │   │ Pair: waUSDe / wasUSDe                 │
│                  │   │ Fee tier: 500 (0.05%)                   │
│ waUSDe (ERC-4626)│   │                                        │
│ wasUSDe(ERC-4626)│   │ Created by us via                      │
└──────────────────┘   │ NonfungiblePositionManager              │
                       └───────────────────────────────────────┘
```

---

## File Structure

```
src/
├── Vault.sol                              ← THE main contract (811 lines)
└── interfaces/
    ├── IStaticATokenLM.sol                ← Aave wrapper interface (ERC-4626 + rewards)
    ├── ISwapRouter.sol                    ← Uniswap v3 SwapRouter (simplified)
    └── INonfungiblePositionManager.sol    ← Uniswap v3 Position Manager (simplified)
```

### Why simplified interfaces?

The Uniswap v3 periphery contracts use **OpenZeppelin v3** (pragma `>=0.7.5`) with complex inheritance chains (`IERC721Metadata`, `IERC721Enumerable`, `IERC721Permit`, etc.). Our project uses **OpenZeppelin v5** with Solidity `0.8.24`. Importing the full interfaces would cause **pragma version conflicts**.

**Solution:** We define simplified local interfaces containing **only the functions we actually call**. This is a standard pattern for DeFi integrations.

---

## Interfaces

### IStaticATokenLM

Extends IERC20 with ERC-4626 vault functions + Aave reward claiming:

| Function | What it does |
|----------|-------------|
| `deposit(assets, receiver)` | Deposit underlying (USDe) → mint shares (waUSDe) |
| `redeem(shares, receiver, owner)` | Burn shares (waUSDe) → send underlying (USDe) to receiver |
| `withdraw(assets, receiver, owner)` | Burn shares to send exact amount of underlying |
| `convertToShares(assets)` | Preview: how many shares for N underlying? |
| `convertToAssets(shares)` | Preview: how many underlying for N shares? |
| `asset()` | Returns the underlying token address |
| `claimRewards(receiver)` | **Aave-specific**: claim liquidity mining rewards |

### ISwapRouter

Only one function needed:

| Function | What it does |
|----------|-------------|
| `exactInputSingle(params)` | Swap exact amount of input token for maximum output |

### INonfungiblePositionManager

Four functions needed:

| Function | What it does |
|----------|-------------|
| `createAndInitializePoolIfNecessary(...)` | Create the waUSDe/wasUSDe pool |
| `mint(params)` | Add liquidity → get NFT position |
| `decreaseLiquidity(params)` | Remove liquidity (accounting only!) |
| `collect(params)` | Actually transfer tokens out after decrease |

---

## State Variables

All protocol addresses are **`immutable`** — set once in the constructor, stored in contract bytecode. This saves gas and prevents admin manipulation.

```solidity
IERC20 public immutable usde;                    // USDe token
IERC20 public immutable susde;                   // sUSDe token
IStaticATokenLM public immutable waUSDe;         // Aave wrapper for USDe
IStaticATokenLM public immutable wasUSDe;        // Aave wrapper for sUSDe
INonfungiblePositionManager public immutable positionManager;  // Uniswap LP manager
ISwapRouter public immutable swapRouter;         // Uniswap swap router
uint24 public immutable poolFee;                 // Pool fee tier (500 or 3000)
address public immutable owner;                  // Deployer (receives rewards)

mapping(address => uint256[]) public userPositions;  // User → NFT position IDs
```

### Why `immutable`?
- Stored in contract bytecode, not storage slots
- Costs **zero gas** to read (PUSH instead of SLOAD)
- Cannot be changed after deployment (no admin-key risk)

### Why `mapping(address => uint256[])`?
- The Vault holds all LP NFTs on behalf of users
- We need to track which user owns which NFT
- Array allows multiple positions per user
- Checked in `removeLiquidityAndWithdraw` for ownership verification

---

## Constructor

The constructor does two things:

### 1. Store all protocol addresses

```solidity
usde = IERC20(_usde);
susde = IERC20(_susde);
waUSDe = IStaticATokenLM(_waUSDe);
// ... etc
```

### 2. Pre-approve all protocol contracts with max allowance

```solidity
// Vault → Aave: let Aave pull USDe/sUSDe from Vault
IERC20(_usde).approve(_waUSDe, type(uint256).max);
IERC20(_susde).approve(_wasUSDe, type(uint256).max);

// Vault → Uniswap SwapRouter: let router pull waUSDe/wasUSDe from Vault
IERC20(_waUSDe).approve(_swapRouter, type(uint256).max);
IERC20(_wasUSDe).approve(_swapRouter, type(uint256).max);

// Vault → Uniswap PositionManager: let PM pull waUSDe/wasUSDe for LP
IERC20(_waUSDe).approve(_positionManager, type(uint256).max);
IERC20(_wasUSDe).approve(_positionManager, type(uint256).max);
```

**Why max approval in constructor?**
- Saves **~20,000 gas per transaction** (no repeated `approve()` calls)
- Safe because Aave and Uniswap are battle-tested, audited protocols
- The Vault only holds tokens **transiently** during operations (never stores user funds long-term, except LP NFTs)

---

## Function: `swap()`

**Signature:** `swap(address tokenIn, uint256 amountIn, uint256 amountOutMin) → uint256 amountOut`

**This is the most important function — the core feature of the project.**

### What the user does
```
1. usde.approve(vault, 100e18)       ← allow Vault to pull tokens
2. vault.swap(usdeAddress, 100e18, 99e18)  ← swap 100 USDe, want ≥99 sUSDe
3. Receives sUSDe in their wallet    ← done!
```

### What happens inside (step by step)

```
Step 0: VALIDATE INPUT
├── Is tokenIn USDe or sUSDe? (revert InvalidToken if not)
├── Is amountIn > 0? (revert ZeroAmount if not)
└── Determine direction: isUsdeIn = true/false

Step 1: DETERMINE TOKEN PATHS
├── If USDe in → staticIn = waUSDe, staticOut = wasUSDe
└── If sUSDe in → staticIn = wasUSDe, staticOut = waUSDe

Step 2: PULL TOKENS FROM USER
└── underlyingIn.transferFrom(user → vault, amountIn)
    ⚠ User must have approved Vault beforehand

Step 3: WRAP VIA AAVE
├── staticIn.deposit(amountIn, vault)
├── USDe → waUSDe (or sUSDe → wasUSDe)
└── Returns wrappedAmount (may differ from amountIn due to exchange rate)

Step 4: SWAP ON UNISWAP V3
├── swapRouter.exactInputSingle({
│     tokenIn:  waUSDe address,
│     tokenOut: wasUSDe address,
│     fee:      poolFee (500),
│     recipient: vault,           ← vault receives, will unwrap
│     amountIn:  wrappedAmount,
│     amountOutMinimum: convertToShares(amountOutMin),  ← KEY!
│     sqrtPriceLimitX96: 0        ← no price limit
│   })
└── Returns wrappedOut (wasUSDe amount)

Step 5: UNWRAP VIA AAVE
├── staticOut.redeem(wrappedOut, user, vault)
├── wasUSDe → sUSDe sent directly to user
└── Returns amountOut (underlying received)

Step 6: EMIT EVENT
└── Swapped(user, tokenIn, tokenOut, amountIn, amountOut)
```

### Slippage Protection: The `convertToShares` Trick

The user specifies `amountOutMin` in **underlying terms** (e.g., "I want at least 99 sUSDe"). But Uniswap's `amountOutMinimum` is in **wrapped token terms** (wasUSDe shares).

We bridge this gap:
```solidity
amountOutMinimum: staticOut.convertToShares(amountOutMin)
// 99 sUSDe → ~98.95 wasUSDe shares (because share price > 1.0)
```

This ensures the user's slippage tolerance is correctly enforced at the Uniswap level, while the user thinks in familiar underlying token amounts.

---

## Function: `depositAndAddLiquidity()`

**Signature:** `depositAndAddLiquidity(uint256 amountUSDe, uint256 amountsUSDe, int24 tickLower, int24 tickUpper) → (uint256 tokenId, uint128 liquidity)`

### What it does

User deposits USDe + sUSDe → Vault wraps both → adds liquidity to the Uniswap v3 pool → returns an NFT position ID.

### Step-by-step flow

```
Step 1: PULL BOTH TOKENS FROM USER
├── usde.transferFrom(user → vault, amountUSDe)
└── susde.transferFrom(user → vault, amountsUSDe)

Step 2: WRAP BOTH VIA AAVE
├── waUSDe.deposit(amountUSDe, vault) → wrappedUSDe shares
└── wasUSDe.deposit(amountsUSDe, vault) → wrappedsUSDe shares

Step 3+4: SORT TOKENS + MINT POSITION (delegated to _mintPosition)
├── Sort waUSDe/wasUSDe by address (token0 < token1)
├── Call positionManager.mint() with sorted tokens + tick range
├── Refund any leftover tokens Uniswap didn't use
└── Returns (tokenId, liquidity)

Step 5: STORE POSITION FOR USER
└── userPositions[msg.sender].push(tokenId)

Step 6: EMIT EVENT
└── LiquidityAdded(user, tokenId, amountUSDe, amountsUSDe, liquidity)
```

### Why a tick range?

Uniswap v3 uses **concentrated liquidity**. Instead of providing liquidity across all prices (0 → ∞), you choose a specific price range via `tickLower` and `tickUpper`.

For a stablecoin pair like USDe/sUSDe (≈ 1:1), you might use:
- **Full range:** `tickLower = -887270`, `tickUpper = 887270`
- **Tight range:** `tickLower = -100`, `tickUpper = 100`

**Important:** Ticks must be multiples of the tick spacing:
| Fee tier | Tick spacing |
|----------|-------------|
| 500 (0.05%) | 10 |
| 3000 (0.3%) | 60 |

### Why leftover refund?

Uniswap v3 may not use 100% of both tokens. The actual ratio depends on the current pool price relative to the tick range. Whatever Uniswap didn't use, we **redeem back to underlying** and return to the user.

---

## Function: `removeLiquidityAndWithdraw()`

**Signature:** `removeLiquidityAndWithdraw(uint256 positionId, uint128 liquidity)`

### What it does

Reverse of `depositAndAddLiquidity`. Removes liquidity from Uniswap, unwraps the staticATokens, and sends the underlying USDe + sUSDe back to the user.

### The critical two-step withdrawal

⚠ **This is the #1 most common Uniswap LP bug:**

Uniswap v3 has a **two-step withdrawal process:**

1. **`decreaseLiquidity()`** — Only "accounts" the tokens (marks them as owed)
2. **`collect()`** — Actually **transfers** the tokens out

If you only call `decreaseLiquidity` without `collect`, the tokens remain **permanently locked** in the PositionManager!

### Step-by-step flow

```
Step 1: VERIFY OWNERSHIP
├── Loop through userPositions[msg.sender]
├── Check if positionId exists in the array
└── Revert NotPositionOwner if not found

Step 2: DECREASE LIQUIDITY (accounting only)
├── positionManager.decreaseLiquidity(positionId, liquidity, ...)
└── Tokens are marked as "owed" but NOT transferred yet!

Step 3: COLLECT (actual transfer)
├── positionManager.collect(positionId, vault, max, max)
├── Collects ALL owed tokens (liquidity removal + swap fees)
└── Vault receives waUSDe + wasUSDe

Step 4: DETERMINE TOKEN ORDERING
├── Figure out which of collected0/collected1 is waUSDe vs wasUSDe
└── Based on address sorting (same logic as deposit)

Step 5: UNWRAP VIA AAVE
├── waUSDe.redeem(waUsdeAmount, user, vault) → sends USDe to user
└── wasUSDe.redeem(wasUsdeAmount, user, vault) → sends sUSDe to user

Step 6: EMIT EVENT
└── LiquidityRemoved(user, positionId, usdeReceived, susdeReceived)
```

---

## Function: `claimRewards()`

**Signature:** `claimRewards()` — admin-only

### What it does

Claims Aave liquidity mining rewards (e.g., stkAAVE tokens) from both StaticAToken wrappers and sends them to the contract owner.

```solidity
waUSDe.claimRewards(owner);   // Claim from USDe wrapper
wasUSDe.claimRewards(owner);  // Claim from sUSDe wrapper
```

### Why admin-only? (Hackathon simplification)

In production, rewards would be distributed **proportionally** to each LP based on their share of total liquidity. This requires:
- Tracking each user's liquidity share
- Implementing a reward accumulator pattern (like Synthetix's StakingRewards)
- Handling precise fixed-point math

For the hackathon, we send all rewards to the admin and explain proportional distribution as "future work" in the demo video.

---

## View Functions

### `getUserPositions(address user) → uint256[]`
Returns all Uniswap v3 NFT position IDs belonging to a user. Useful for frontends to display LP positions.

### `getUserPositionCount(address user) → uint256`
Returns the count of positions. Useful for quick checks without retrieving the full array.

### `previewSwap(address tokenIn, uint256 amountIn) → uint256 estimatedOut`

**Approximate** calculation of swap output using only Aave exchange rates. Does NOT account for Uniswap slippage, price impact, or fees.

```
Formula:
1. sharesIn = staticIn.convertToShares(amountIn)   ← how many shares for input
2. Assume 1:1 swap on Uniswap                       ← approximation for stablecoins
3. estimatedOut = staticOut.convertToAssets(sharesIn) ← shares back to underlying
```

For accurate quotes, use the **Uniswap API** (`POST /v2/quote`).

---

## Internal Helpers

### `_mintPosition(wrappedUSDe, wrappedsUSDe, tickLower, tickUpper) → (tokenId, liquidity)`

Extracted from `depositAndAddLiquidity` to solve the **"stack too deep"** compiler error.

**Why this exists:** The EVM limits each function to **16 stack slots** for local variables. `depositAndAddLiquidity` had too many locals (input amounts + wrapped amounts + sorted tokens + mint params + return values). By splitting the mint logic into a separate `internal` function, each function stays under the limit.

**What it does:**
1. Sorts waUSDe/wasUSDe by address (Uniswap requirement)
2. Calls `positionManager.mint()` with the sorted tokens
3. Refunds leftover tokens via `_refundLeftover`

### `_refundLeftover(address wrappedToken, uint256 leftover)`

Redeems unused wrapped tokens back to underlying and sends them to the user. Called after minting an LP position because Uniswap may not use 100% of both tokens.

---

## Approval Chain

Every token transfer between contracts requires a prior `approve()`. Here is the **complete approval chain**:

```
USER → VAULT:
  user calls usde.approve(vault, amount)     ← before swap or LP deposit
  user calls susde.approve(vault, amount)    ← before swap or LP deposit

VAULT → AAVE (set once in constructor, max):
  vault calls usde.approve(waUSDe, MAX)      ← for Aave deposits
  vault calls susde.approve(wasUSDe, MAX)    ← for Aave deposits

VAULT → UNISWAP SWAPROUTER (set once in constructor, max):
  vault calls waUSDe.approve(swapRouter, MAX)   ← for swaps
  vault calls wasUSDe.approve(swapRouter, MAX)  ← for swaps

VAULT → UNISWAP POSITION MANAGER (set once in constructor, max):
  vault calls waUSDe.approve(positionManager, MAX)   ← for adding liquidity
  vault calls wasUSDe.approve(positionManager, MAX)  ← for adding liquidity
```

**Total approvals: 6 in constructor + 2 per user transaction.**

The Vault→protocol approvals are set once with `type(uint256).max` in the constructor. Only user→Vault approvals need to happen per transaction.

---

## Token Ordering

**This is the #1 source of bugs when working with Uniswap v3.**

Uniswap requires `token0 < token1` (compared as `uint160` addresses). Get this wrong and every call reverts with a cryptic error.

```solidity
if (address(waUSDe) < address(wasUSDe)) {
    token0 = address(waUSDe);   // lower address is token0
    token1 = address(wasUSDe);  // higher address is token1
    amount0 = wrappedUSDe;      // amounts must match!
    amount1 = wrappedsUSDe;
} else {
    token0 = address(wasUSDe);
    token1 = address(waUSDe);
    amount0 = wrappedsUSDe;
    amount1 = wrappedUSDe;
}
```

This sorting is done in:
- `_mintPosition()` — when adding liquidity
- `removeLiquidityAndWithdraw()` — when determining which collected token is which

---

## Events

| Event | When emitted | Key data |
|-------|-------------|----------|
| `Swapped` | After a successful swap | user, tokenIn, tokenOut, amountIn, amountOut |
| `LiquidityAdded` | After adding LP | user, tokenId, amounts, liquidity |
| `LiquidityRemoved` | After removing LP | user, tokenId, amounts received |
| `RewardsClaimed` | After claiming Aave rewards | admin address |

Events are critical for:
- **Demo scripts** — proving onchain execution with tx hashes
- **Block explorers** — viewing contract activity
- **The Graph** — indexing for frontends

---

## Custom Errors

We use **custom errors** instead of `require(string)` because they:
- Save gas (no string storage on-chain)
- Give better debugging messages in etherscan
- Are the modern Solidity best practice (0.8.4+)

| Error | When thrown |
|-------|-----------|
| `InvalidToken()` | tokenIn is not USDe or sUSDe |
| `ZeroAmount()` | amountIn is zero |
| `NotPositionOwner()` | User trying to remove LP they don't own |
| `OnlyOwner()` | Non-admin calling claimRewards() |
| `TransferFailed()` | ERC-20 transferFrom returned false |

---

## Design Decisions

### 1. Simplified local interfaces vs. importing Uniswap/Aave
**Decision:** Define our own minimal interfaces.
**Why:** Avoids OpenZeppelin v3 vs v5 pragma conflicts that would prevent compilation.

### 2. Max approvals in constructor vs. per-transaction approvals
**Decision:** Max approve in constructor.
**Why:** Saves ~20k gas per operation. Safe because we're approving to audited protocols (Aave, Uniswap), not arbitrary contracts.

### 3. `_mintPosition` internal helper vs. single function
**Decision:** Extract into helper.
**Why:** Solves "stack too deep" EVM compiler error without enabling `via_ir` (which significantly slows compilation).

### 4. Admin reward claiming vs. proportional distribution
**Decision:** Admin-only for hackathon.
**Why:** Proportional distribution requires complex reward accumulator math. For demo purposes, we explain the production approach in the video.

### 5. Array-based position tracking vs. mapping
**Decision:** `mapping(address => uint256[])` — array of NFT IDs per user.
**Why:** Allows multiple positions per user, easy to enumerate for frontends. O(n) lookup is acceptable for hackathon (users have few positions).

### 6. `block.timestamp` as deadline vs. user-provided deadline
**Decision:** `block.timestamp` for swaps, `block.timestamp + 600` for LP operations.
**Why:** For swaps, execute immediately or not at all. For LP, allow 10 minutes for the transaction to be mined.

---

## Common Pitfalls Avoided

| Pitfall | How we handle it |
|---------|-----------------|
| Forgetting to sort token0/token1 by address | Explicit sorting in `_mintPosition` and `removeLiquidityAndWithdraw` |
| Missing an approval in the chain | All 6 Vault→protocol approvals in constructor |
| Using wrong fee tier value (0.05 vs 500) | Stored as `uint24 poolFee` immutable, set once |
| Tick values not multiples of spacing | Documented in comments; user responsibility |
| Using aTokens directly (rebasing) | Always wrap via StaticATokenLM first |
| Wrong slippage units (underlying vs shares) | `convertToShares(amountOutMin)` conversion |
| Forgetting `collect()` after `decreaseLiquidity()` | Both called in sequence in `removeLiquidityAndWithdraw` |
| Leftover tokens stuck in Vault after LP | `_refundLeftover` redeems and returns to user |
