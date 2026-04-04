# Yield-Enhanced Swap — Full Project Context for Claude

You are helping build a hackathon project for the **Uniswap API track**. Read this entire file before writing any code.

## Project Goal

Build a system where users can **swap USDe <> sUSDe** or **provide liquidity** for this pair, but the underlying Uniswap pool actually holds **Aave-wrapped versions** of these tokens. This gives LPs extra yield from Aave on top of normal Uniswap swap fees.

## Hackathon Track Requirements

This project is for the Uniswap API hackathon track. Requirements:
- Must integrate the **Uniswap API with a valid API key** from developers.uniswap.org
- Must produce **transaction IDs** showing real onchain execution (testnet and/or mainnet)
- Public GitHub repo with open-source code and clear README.md
- Demo video (max 3 minutes)
- No UI required — scripts/CLI are fine

## The Core Problem & Solution

### The problem with aTokens
Aave's aTokens are **rebasing**: their balance increases over time as lending yield accrues. If you put aTokens directly into a Uniswap pool, the pool contract doesn't know about the rebase — the extra balance becomes "phantom" reserves that break AMM pricing and can be arbitraged.

### The solution: StaticATokenLM (ERC-4626)
Aave provides **StaticATokenLM** wrappers. These are ERC-4626 vaults that wrap aTokens into a **non-rebasing** token. Instead of the balance increasing, the **share price** increases. 1 waUSDe might be worth 1.001 USDe today and 1.002 USDe tomorrow, but the balance stays constant. This is safe for Uniswap pools.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      USER                                │
│              (holds USDe and/or sUSDe)                   │
└──────────────┬──────────────────────┬───────────────────┘
               │ swap()               │ depositAndAddLiquidity()
               ▼                      ▼
┌─────────────────────────────────────────────────────────┐
│                   VAULT CONTRACT                         │
│                   (we write this)                         │
│                                                          │
│  Responsibilities:                                       │
│  1. Accept USDe/sUSDe from users                         │
│  2. Deposit into Aave StaticATokenLM → get waUSDe/wasUSDe│
│  3. Interact with Uniswap pool (swap or add liquidity)   │
│  4. On withdrawal: unwrap staticATokens back to USDe/sUSDe│
│  5. Claim and distribute Aave incentive rewards (bonus)  │
└──────────┬───────────────────┬──────────────────────────┘
           │                   │
           ▼                   ▼
┌──────────────────┐  ┌──────────────────────────────────┐
│ Aave v3          │  │ Uniswap v3 Pool                   │
│ StaticATokenLM   │  │ Pair: waUSDe / wasUSDe            │
│                  │  │ Fee tier: 500 (0.05%) recommended  │
│ waUSDe (ERC-4626)│  │                                    │
│ wasUSDe(ERC-4626)│  │ Created by us via                  │
└──────────────────┘  │ NonfungiblePositionManager         │
                      └──────────────────────────────────┘
```

## What the Vault Contract Does — Function by Function

### `swap(address tokenIn, uint256 amountIn, uint256 amountOutMin)`

This is the **most important function** — build it first.

Step-by-step logic:
```
1. Determine which token is input, which is output
   - If tokenIn == USDe, then output is sUSDe (and vice versa)
   - Determine the corresponding staticAToken wrappers for each

2. Pull input tokens from user
   - IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn)

3. Wrap input into staticAToken via Aave
   - IERC20(tokenIn).approve(address(staticATokenIn), amountIn)
   - uint256 wrappedAmount = IStaticATokenLM(staticATokenIn).deposit(amountIn, address(this))

4. Swap on Uniswap v3 pool
   - IERC20(staticATokenIn).approve(address(swapRouter), wrappedAmount)
   - Call swapRouter.exactInputSingle() with:
     - tokenIn: address of staticATokenIn (waUSDe or wasUSDe)
     - tokenOut: address of staticATokenOut
     - fee: pool fee tier (500 or 3000)
     - recipient: address(this)  ← vault receives the output
     - amountIn: wrappedAmount
     - amountOutMinimum: calculate based on amountOutMin (need to convert from underlying to shares)
     - sqrtPriceLimitX96: 0 (no price limit)

5. Unwrap output staticAToken back to underlying
   - uint256 outputAmount = IStaticATokenLM(staticATokenOut).redeem(swapOutput, msg.sender, address(this))
   - This sends the underlying token (USDe or sUSDe) directly to the user

6. Emit event with tx details
```

### `depositAndAddLiquidity(uint256 amountUSDe, uint256 amountsUSDe, int24 tickLower, int24 tickUpper)`

LP function — build second.

```
1. Pull BOTH tokens from user
   - transferFrom for USDe and sUSDe

2. Wrap both into staticATokens
   - deposit USDe → waUSDe
   - deposit sUSDe → wasUSDe

3. Approve both staticATokens to NonfungiblePositionManager

4. Call positionManager.mint() with MintParams:
   - token0/token1: waUSDe and wasUSDe (MUST be sorted by address, lower first)
   - fee: pool fee tier
   - tickLower/tickUpper: the range (must be multiples of tick spacing)
   - amount0Desired/amount1Desired: the wrapped amounts
   - amount0Min/amount1Min: can be 0 for hackathon (in prod, use slippage protection)
   - recipient: address(this)  ← vault holds the NFT
   - deadline: block.timestamp + 600

5. Store the position NFT ID for this user
   - mapping(address => uint256[]) public userPositions;
   - userPositions[msg.sender].push(tokenId);

6. Refund any leftover tokens that weren't used by the position
```

### `removeLiquidityAndWithdraw(uint256 positionId, uint128 liquidity)`

Reverse of the above:
```
1. Verify msg.sender owns this position (check userPositions mapping)
2. Call positionManager.decreaseLiquidity() → removes liquidity
3. Call positionManager.collect() → actually transfers the tokens out
4. Redeem both staticATokens back to underlying via Aave
5. Send USDe and sUSDe back to user
```

### `claimRewards()` — Nice to have, build last

```
1. Call staticATokenUSDe.claimRewards(address(this))
2. Call staticATokensUSDe.claimRewards(address(this))
3. Distribute reward tokens proportionally to LPs based on their liquidity share
   (For hackathon: just send all rewards to a single admin address and explain
    proportional distribution in the video as "future work")
```

## Contract State Variables

```solidity
// Immutable addresses (set in constructor)
IERC20 public immutable usde;
IERC20 public immutable susde;
IStaticATokenLM public immutable waUSDe;   // staticAToken wrapper for USDe
IStaticATokenLM public immutable wasUSDe;  // staticAToken wrapper for sUSDe
INonfungiblePositionManager public immutable positionManager;
ISwapRouter public immutable swapRouter;
uint24 public immutable poolFee;            // 500 or 3000

// LP tracking
mapping(address => uint256[]) public userPositions;  // NFT token IDs per user
```

## Key Interfaces

```solidity
// Aave StaticATokenLM — implements ERC-4626
interface IStaticATokenLM is IERC4626 {
    // Standard ERC-4626:
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    // Aave-specific:
    function claimRewards(address receiver) external;
}

// Uniswap v3 SwapRouter
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
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
    function mint(MintParams calldata params)
        external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external returns (uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params)
        external returns (uint256 amount0, uint256 amount1);

    function createAndInitializePoolIfNecessary(
        address token0, address token1, uint24 fee, uint160 sqrtPriceX96
    ) external returns (address pool);
}
```

## Approval Chain (Critical — Many bugs here)

Every token transfer between contracts needs a prior `approve()`. Here is every approval needed:

```
USER → VAULT:
  user calls usde.approve(vault, amount)    before swap or LP deposit
  user calls susde.approve(vault, amount)   before swap or LP deposit

VAULT → AAVE STATIC WRAPPER:
  vault calls usde.approve(waUSDe, amount)   before depositing to Aave
  vault calls susde.approve(wasUSDe, amount) before depositing to Aave

VAULT → UNISWAP:
  vault calls waUSDe.approve(swapRouter, amount)          before swaps
  vault calls wasUSDe.approve(swapRouter, amount)         before swaps
  vault calls waUSDe.approve(positionManager, amount)     before adding liquidity
  vault calls wasUSDe.approve(positionManager, amount)    before adding liquidity
```

**Optimization:** The Vault can set max approvals to Aave and Uniswap contracts in the constructor (these are trusted protocols). Only user→Vault approvals need to happen per-transaction.

## Token Ordering for Uniswap

Uniswap v3 requires `token0 < token1` (by address, uint160 comparison). When creating the pool or minting positions:
```solidity
(address token0, address token1) = address(waUSDe) < address(wasUSDe)
    ? (address(waUSDe), address(wasUSDe))
    : (address(wasUSDe), address(waUSDe));
```
Get this wrong and every call reverts.

## Initial Pool Price (sqrtPriceX96)

For a 1:1 price ratio (both tokens ≈ $1):
```
sqrtPriceX96 = sqrt(1) * 2^96 = 79228162514264337593543950336
```

If sUSDe is worth more than USDe (because sUSDe accrues Ethena staking yield), adjust:
```
sqrtPriceX96 = sqrt(priceOfToken1InToken0) * 2^96
```
Where price = how many token0 per 1 token1. Token0 is the lower address.

## Tick Spacing by Fee Tier

| Fee (bps) | Fee tier value | Tick spacing |
|-----------|---------------|-------------|
| 1 (0.01%) | 100 | 1 |
| 5 (0.05%) | 500 | 10 |
| 30 (0.3%) | 3000 | 60 |
| 100 (1%) | 10000 | 200 |

`tickLower` and `tickUpper` must be multiples of the tick spacing. For full range on 0.05% pool:
```solidity
int24 tickLower = -887270;  // nearest multiple of 10 to MIN_TICK
int24 tickUpper = 887270;   // nearest multiple of 10 to MAX_TICK
```

## Development Approach

### Local development: mainnet fork
```bash
anvil --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY --chain-id 31337
```
This gives you access to real Aave, real Uniswap, real USDe/sUSDe — no mocks needed.

Use `cast send --unlocked --from <whale>` to get test tokens.

### Testnet deployment: Sepolia with mocks
USDe/sUSDe likely don't exist on Aave Sepolia. Deploy:
1. MockUSDe (simple ERC-20 with mint function)
2. MocksUSDe (simple ERC-20 with mint function)
3. MockStaticAToken for each (simple ERC-4626 vault — deposit gives shares, redeem gives assets, no actual yield needed for demo)
4. Deploy Vault pointing to mocks
5. Create Uniswap pool on Sepolia with the mock static tokens

### Mainnet: one small tx
Do at least one real swap or LP deposit on mainnet with $5-10 worth of tokens for the submission.

## Uniswap API Integration

The hackathon **requires** use of the Uniswap API with an API key. Use it for:

1. **Quoting** — get the best swap route and expected output
2. **Swap execution** — get encoded calldata for the Universal Router

```
API base: https://api.uniswap.org
Auth header: x-api-key: YOUR_KEY

POST /v2/quote   → get quote for a swap
POST /v2/swap    → get tx calldata to execute
POST /v1/check-approval → check if router is approved
```

The API may not route through your custom Sepolia pool. That's fine — use it for mainnet demo or to show you can quote standard pairs. The Vault contract handles direct pool interaction for your custom pool.

## File Structure (Foundry project)

```
yield-enhanced-swap/
├── src/
│   ├── Vault.sol                 ← THE main contract
│   ├── interfaces/
│   │   ├── IStaticATokenLM.sol
│   │   ├── ISwapRouter.sol
│   │   └── INonfungiblePositionManager.sol
│   └── mocks/                    ← for Sepolia deployment
│       ├── MockERC20.sol
│       └── MockStaticAToken.sol  ← simple ERC-4626
├── script/
│   ├── Deploy.s.sol              ← deploy Vault + create pool
│   └── Demo.s.sol                ← run full demo flow
├── test/
│   └── Vault.t.sol               ← fork tests
├── scripts/
│   └── uniswap-api.ts            ← Uniswap API integration (TypeScript)
├── .env.example
├── foundry.toml
├── CLAUDE.md                     ← this file
└── README.md                     ← public readme
```

## What "Done" Looks Like

Minimum viable submission:
1. Vault.sol deployed (Sepolia or mainnet)
2. Uniswap v3 pool created with waUSDe/wasUSDe (or mocks)
3. At least one swap executed through the Vault
4. Uniswap API used for quoting or routing (with API key)
5. Transaction IDs collected for submission
6. 3-minute demo video

## Build Priority

1. **swap()** function in Vault — most demonstrable, simplest
2. **Pool creation** script — needed for swap to work
3. **depositAndAddLiquidity()** — shows the full value prop
4. **Uniswap API script** — required by hackathon
5. **removeLiquidityAndWithdraw()** — completes the LP flow
6. **claimRewards()** — cherry on top, skip if short on time

## Common Mistakes to Avoid

- Forgetting to sort token0/token1 by address
- Missing an approval in the chain (there are 6+ approvals needed)
- Using wrong fee tier value (500, not 0.05)
- Tick values not being multiples of tick spacing
- Trying to use aTokens directly instead of StaticATokenLM
- Not converting between underlying amounts and share amounts when setting slippage
- Forgetting to call collect() after decreaseLiquidity() (decrease removes liquidity, collect actually transfers tokens)
