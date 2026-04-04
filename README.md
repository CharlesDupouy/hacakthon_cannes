# Yield-Enhanced Swap — Uniswap v4 Hook + Aave

> Hackathon project — Uniswap API Track

## What it does

Users swap **USDC <> USDT** through a simple interface.
Under the hood, the **Uniswap v4 pool** holds **Aave StaticATokenLM** (non-rebasing ERC-4626) versions of both tokens.
Liquidity providers earn **Uniswap swap fees + Aave lending yield simultaneously**.

```
User sends USDC
     │
     ▼
┌─────────────────────────────────────────┐
│             YieldHook.sol               │
│   (Uniswap v4 Hook — our code)          │
│                                         │
│  swap() / addLiquidity() / remove()     │
│  1. Pull USDC from user                 │
│  2. Deposit USDC → Aave → stataUSDC     │
│  3. Interact with Uniswap v4 pool       │
│     (pool holds stataUSDC/stataUSDT)    │
│  4. Redeem stataUSDT → USDT             │
│  5. Send USDT to user                   │
└─────────────────────────────────────────┘
     │
     ▼
Aave yield accrues inside stataToken share price
(not via balance rebasing — safe for AMM math)
```

### Why StaticATokenLM (stataTokens)?

Aave's aTokens rebase: the balance increases over time as interest accrues. This breaks Uniswap's constant-product AMM math. Aave's `StaticATokenLM` is a non-rebasing ERC-4626 wrapper: instead of the balance growing, the **share price** grows. The pool balance stays constant while value accrues — exactly what we need.

---

## Deployed Contracts — Base Sepolia (chain 84532)

### Our contracts

| Contract | Address | Notes |
|---|---|---|
| YieldHook | `0xBdF688ee8034C64B8f75ddEBf4468634586FD000` | v4 hook, afterInitialize only |

### Uniswap v4 pool

| Parameter | Value |
|---|---|
| currency0 | stataUSDC `0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a` |
| currency1 | stataUSDT `0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F` |
| Fee | 0.05% (500) |
| Tick spacing | 10 |
| Hook | YieldHook above |

### Aave v3 on Base Sepolia (real deployment, no mocks)

| Contract | Address |
|---|---|
| USDC (TestnetERC20) | `0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f` |
| USDT (TestnetERC20) | `0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a` |
| stataUSDC (StaticATokenLM) | `0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a` |
| stataUSDT (StaticATokenLM) | `0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F` |
| Aave v3 Pool | `0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27` |
| Aave Faucet | `0xD9145b5F45Ad4519c7acCd6e0A4A82E83bB8A6Dc` |

### Uniswap v4 on Base Sepolia

| Contract | Address |
|---|---|
| PoolManager | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |

---

## Transaction History (Base Sepolia)

| Action | Tx Hash |
|---|---|
| Deploy YieldHook | `0xcd2f9a49cc897fe096c4b98ff24a128505a1c8c442c9edc2849aefad53dc133a` |
| Initialize pool | `0x05d01370d711283ea8a382851d4762465a5e9bd4ee4dc132114ba4d7dc21bf0c` |
| Add liquidity (100 USDC + 100 USDT) | `0x64a0a575b504a0e634d0e09c1727dfe0f6e6dff7f0ffcc4183326af75bbd3ff9` |
| Swap (10 USDC -> USDT) | `0xb768732ba7c07fed057f44c295ac52f4dd2a039063f2886549b2dfa7518635f4` |

All transactions visible on [BaseScan Sepolia](https://sepolia.basescan.org).

---

## How to run

### Prerequisites

```bash
git clone <repo> && cd hackathon-cannes
forge install
cp .env.example .env   # fill in PRIVATE_KEY, BASE_SEPOLIA_RPC_URL, UNISWAP_API_KEY
```

### Get test tokens (Aave faucet — only way to get testnet USDC/USDT)

```bash
source .env
cast send 0xD9145b5F45Ad4519c7acCd6e0A4A82E83bB8A6Dc \
  "mint(address,address,uint256)" \
  0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f $YOUR_ADDRESS 10000000000 \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

cast send 0xD9145b5F45Ad4519c7acCd6e0A4A82E83bB8A6Dc \
  "mint(address,address,uint256)" \
  0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a $YOUR_ADDRESS 10000000000 \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

### Add liquidity

```bash
source .env
export YIELD_HOOK_ADDRESS=0xBdF688ee8034C64B8f75ddEBf4468634586FD000
forge script script/AddLiquidityV4.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Swap (10 USDC -> USDT)

```bash
source .env
export YIELD_HOOK_ADDRESS=0xBdF688ee8034C64B8f75ddEBf4468634586FD000
forge script script/SwapV4.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Remove liquidity

```bash
source .env
export YIELD_HOOK_ADDRESS=0xBdF688ee8034C64B8f75ddEBf4468634586FD000
export POSITION_ID=0
forge script script/RemoveLiquidityV4.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Uniswap API demo (TypeScript)

```bash
cd scripts && npm install
# Dry run (no tx submitted):
npx tsx uniswap-api.ts
# Execute swap on-chain:
npx tsx uniswap-api.ts --execute
```

Requires `UNISWAP_API_KEY` in `.env` (get from [developers.uniswap.org](https://developers.uniswap.org)).

---

## File structure

```
src/
  YieldHook.sol           # Core hook — wraps/unwraps Aave, manages LP positions
  interfaces/
    IStaticATokenLM.sol   # Aave StaticATokenLM interface (ERC-4626 + claimRewards)

script/
  DeployYieldHook.s.sol   # CREATE2 mining + deploy (already done)
  InitializePool.s.sol    # Create the v4 pool (already done)
  AddLiquidityV4.s.sol    # Add 100 USDC + 100 USDT as full-range liquidity
  SwapV4.s.sol            # Swap 10 USDC -> USDT through the hook
  RemoveLiquidityV4.s.sol # Remove a position by ID

scripts/
  uniswap-api.ts          # TypeScript: quote + optional execute via Uniswap Trading API
```

---

## Known limitations (testnet demo)

- **Pool initialized at 1:1** — stataUSDC has a higher liquidityIndex (~1.24) than stataUSDT (~1.0) because USDC has accrued more interest on this testnet. This means the true "fair" price is off from the initial pool price, causing non-trivial slippage on small swaps. Acceptable for demo purposes.
- **No rewards on testnet** — `claimRewards()` works but yields nothing on Base Sepolia (no reward emissions).
- **LP position tracking** — YieldHook tracks positions internally (no NFT). In production, a proper LP receipt token would be needed.

---

## Hackathon checklist

- [x] Smart contract deployed on Base Sepolia
- [x] Uniswap v4 pool created with Aave stataToken pair
- [x] Swap executed through the hook (tx ID above)
- [x] LP deposit and withdrawal working
- [x] Uniswap API used for quoting (`scripts/uniswap-api.ts`)
- [ ] 3-minute demo video
- [ ] Uniswap Developer Feedback Form: https://developers.uniswap.org/feedback
