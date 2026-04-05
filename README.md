# PoolUp — Yield-Enhanced Swap on Uniswap v4

> Hackathon project — Uniswap API Track

## What it does

**PoolUp** lets users swap **USDC ↔ USDT** and provide liquidity through a React frontend. Under the hood, the Uniswap v4 pool holds **Aave StaticATokenLM** (stataToken) versions of both tokens — so liquidity providers earn **Uniswap swap fees + Aave lending yield simultaneously**, with no extra steps.

```
User sends USDC
       │
       ▼
┌──────────────────────────────────────────┐
│              PoolUp.sol                  │
│        (Uniswap v4 Hook — our code)      │
│                                          │
│  swap()                                  │
│    1. Pull USDC from user                │
│    2. Deposit USDC → Aave → stataUSDC    │
│    3. Swap stataUSDC → stataUSDT (v4)    │
│    4. Redeem stataUSDT → USDT            │
│    5. Send USDT to user                  │
│                                          │
│  addLiquidity()                          │
│    1. Pull USDC + USDT from user         │
│    2. Wrap both via Aave → stataTokens   │
│    3. Add to v4 pool as concentrated LP  │
│    4. Refund unused stataTokens          │
│                                          │
│  removeLiquidity()                       │
│    1. Burn LP position in v4 pool        │
│    2. Redeem stataTokens → USDC + USDT   │
│    3. Send to user (more than deposited) │
└──────────────────────────────────────────┘
       │
       ▼
 Aave yield accrues inside stataToken share price
 (non-rebasing ERC-4626 — safe for Uniswap math)
```

### Why StaticATokenLM?

Aave's aTokens rebase: the balance increases over time as interest accrues. This breaks Uniswap's constant-product math. Aave's `StaticATokenLM` is a non-rebasing ERC-4626 wrapper: instead of the balance growing, the **share price** grows. The pool balance stays constant while value accrues — exactly what an AMM needs.

---

## Live Demo — Base Sepolia (chain 84532)

### Deployed contracts

| Contract | Address |
|---|---|
| PoolUp | [`0x9F3464b13345cdb221Bc12A4c615a70145eC5000`](https://sepolia.basescan.org/address/0x9F3464b13345cdb221Bc12A4c615a70145eC5000) |
| Uniswap v4 PoolManager | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| USDC (Aave TestnetERC20) | `0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f` |
| USDT (Aave TestnetERC20) | `0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a` |
| stataUSDC (StaticATokenLM) | `0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a` |
| stataUSDT (StaticATokenLM) | `0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F` |
| Aave v3 Pool | `0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27` |
| Aave Faucet | `0xD9145b5F45Ad4519c7acCd6e0A4A82E83bB8A6Dc` |

### Pool configuration

| Parameter | Value |
|---|---|
| currency0 | stataUSDC |
| currency1 | stataUSDT |
| Fee tier | 0.05% (500) |
| Tick spacing | 10 |
| Hook | PoolUp above |

### Proof of working transactions

| Action | Details | Tx |
|---|---|---|
| Add liquidity | 29 USDC + 23.97 USDT → position #0, 21,257,123 liquidity units | [`0x491cf352...`](https://sepolia.basescan.org/tx/0x491cf35249fd7387b640a20fb8f3b0f6097db5309c340e512e19488414eb57be) |
| Swap | 2 USDC → USDT through hook | [`0x37fc0caf...`](https://sepolia.basescan.org/tx/0x37fc0caf5bae94f9a65226db976e8b3d7bb639d7eabd6926dc7260cd2e881486) |
| Remove liquidity | Position #0 removed, USDC + USDT returned | [`0x6d00fb3b...`](https://sepolia.basescan.org/tx/0x6d00fb3b5c16eec2e82ca36b081eb087f926952c0e12dd0df926266ff3b06061) |

---

## Frontend

React app built with wagmi v2 + RainbowKit. Connects to the hook directly via wallet.

**Swap tab:**
- Swap USDC → USDT or USDT → USDC
- Quote fetched from the **Uniswap Trading API** (mainnet reference rate) before executing on Base Sepolia
- Approve + swap in two clicks

**Liquidity tab:**
- Enter one token amount — the other auto-fills based on the live pool price
- Displays liquidity units and fee tier before confirming
- Position list shows each open position with:
  - Estimated receive on removal (live `getAmountsForLiquidity` + `previewRedeem`)
  - P&L % vs original deposit (stored at deposit time as stataToken shares)

### Run locally

```bash
cd frontend
cp .env.example .env   # add VITE_UNISWAP_API_KEY and VITE_WALLETCONNECT_PROJECT_ID
npm install
npm run dev
```

The Vite dev server proxies `/api/uniswap/*` → Uniswap Trading API to avoid CORS issues and keep the API key server-side.

---

## Uniswap API integration

`scripts/uniswap-api.ts` uses the Uniswap Trading API with a valid API key.

It quotes **USDC → USDT on Ethereum mainnet** (chain 1) — testnet tokens are not indexed by the routing API, so mainnet is used to demonstrate real route discovery and quote data. The actual swap executes on Base Sepolia via PoolUp.

```bash
cd scripts && npm install

# Fetch quote only:
npx tsx uniswap-api.ts

# Execute swap on Base Sepolia:
npx tsx uniswap-api.ts --execute
```

Requires `UNISWAP_API_KEY` in `.env` (get from [developers.uniswap.org](https://developers.uniswap.org)).

---

## Smart contract scripts

```bash
source .env

# Get testnet tokens (Aave faucet — only source of testnet USDC/USDT)
cast send 0xD9145b5F45Ad4519c7acCd6e0A4A82E83bB8A6Dc \
  "mint(address,address,uint256)" \
  0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f $YOUR_ADDRESS 10000000000 \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

# Add liquidity
forge script script/AddLiquidityV4.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast

# Swap 10 USDC → USDT
forge script script/SwapV4.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast

# Remove a position (replace 0 with your position ID)
POSITION_ID=0 forge script script/RemoveLiquidityV4.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

---

## Repository structure

```
src/
  PoolUp.sol                  # Core hook — wraps/unwraps Aave, manages LP positions
  interfaces/
    IStaticATokenLM.sol       # Aave StaticATokenLM interface (ERC-4626 + claimRewards)

script/
  DeployPoolUp.s.sol          # CREATE2 mining + deploy
  InitializePool.s.sol        # Create the v4 pool
  AddLiquidityV4.s.sol        # Add USDC + USDT as full-range liquidity
  SwapV4.s.sol                # Swap USDC → USDT through the hook
  RemoveLiquidityV4.s.sol     # Remove a position by ID

scripts/
  uniswap-api.ts              # Uniswap Trading API: quote + optional execute

frontend/
  src/
    components/
      SwapCard.tsx            # Swap UI with Uniswap API quote
      LPCard.tsx              # Add liquidity with auto-paired amounts
      PositionList.tsx        # Positions with estimated receive + P&L %
    liquidityMath.ts          # TypeScript port of LiquidityAmounts.sol
    constants.ts              # Contract addresses + pool storage slot
    abis.ts                   # Contract ABIs
```

---

## Known limitations

- **Pool initialized at 1:1** — stataUSDC has a higher Aave liquidityIndex than stataUSDT on this testnet, so the "fair" internal price differs from 1:1. This causes slight slippage on swaps. Acceptable for demo purposes.
- **No reward emissions on testnet** — `claimRewards()` is implemented and working but yields nothing on Base Sepolia (Aave has no active reward programs there).
- **P&L estimate excludes swap fees** — displaying accumulated fees requires reading `feeGrowthInside` from PoolManager storage slots, which is complex. The P&L shown is principal + Aave yield only; actual receive on removal will be slightly higher.

---

## Hackathon checklist

- [x] PoolUp deployed on Base Sepolia
- [x] Uniswap v4 pool created with Aave stataToken pair
- [x] Add liquidity transaction on-chain
- [x] Swap transaction on-chain
- [x] Remove liquidity transaction on-chain
- [x] Uniswap Trading API used for quoting (`scripts/uniswap-api.ts` + frontend proxy)
- [x] React frontend with swap + LP management
- [ ] 3-minute demo video
- [ ] Uniswap Developer Feedback Form: https://developers.uniswap.org/feedback
