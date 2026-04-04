// Port of Uniswap v4 LiquidityAmounts.sol — same math, pure TypeScript bigint
// Both getLiquidityForAmounts and getAmountsForLiquidity are the exact inverse
// of each other, mirroring the Solidity reference implementation.

const Q96 = 2n ** 96n

function liquidityForAmount0(sqrtA: bigint, sqrtB: bigint, amount0: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA]
  return (amount0 * sqrtA * sqrtB) / (Q96 * (sqrtB - sqrtA))
}

function liquidityForAmount1(sqrtA: bigint, sqrtB: bigint, amount1: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA]
  return (amount1 * Q96) / (sqrtB - sqrtA)
}

export function getLiquidityForAmounts(
  sqrtPrice: bigint,
  sqrtLower: bigint,
  sqrtUpper: bigint,
  amount0: bigint,
  amount1: bigint,
): bigint {
  if (sqrtLower > sqrtUpper) [sqrtLower, sqrtUpper] = [sqrtUpper, sqrtLower]

  if (sqrtPrice <= sqrtLower) {
    return liquidityForAmount0(sqrtLower, sqrtUpper, amount0)
  } else if (sqrtPrice < sqrtUpper) {
    const liq0 = liquidityForAmount0(sqrtPrice, sqrtUpper, amount0)
    const liq1 = liquidityForAmount1(sqrtLower, sqrtPrice, amount1)
    return liq0 < liq1 ? liq0 : liq1
  } else {
    return liquidityForAmount1(sqrtLower, sqrtUpper, amount1)
  }
}

// ─── getAmountsForLiquidity ───────────────────────────────────────────────────
// Inverse of getLiquidityForAmounts.
// Returns the stataToken amounts the pool would return when burning `liquidity`
// at the current sqrtPrice. This is the principal only — swap fees are NOT
// included (they require reading feeGrowthInside from pool storage slots).
//
// Formula (from LiquidityAmounts.sol):
//   amount0 = liquidity * Q96 * (sqrtUpper - sqrtPrice) / (sqrtPrice * sqrtUpper)
//   amount1 = liquidity * (sqrtPrice - sqrtLower) / Q96

function amount0ForLiquidity(sqrtA: bigint, sqrtB: bigint, liquidity: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA]
  return (liquidity * Q96 * (sqrtB - sqrtA)) / sqrtB / sqrtA
}

function amount1ForLiquidity(sqrtA: bigint, sqrtB: bigint, liquidity: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA]
  return (liquidity * (sqrtB - sqrtA)) / Q96
}

export function getAmountsForLiquidity(
  sqrtPrice: bigint,
  sqrtLower: bigint,
  sqrtUpper: bigint,
  liquidity: bigint,
): { amount0: bigint; amount1: bigint } {
  if (sqrtLower > sqrtUpper) [sqrtLower, sqrtUpper] = [sqrtUpper, sqrtLower]

  if (sqrtPrice <= sqrtLower) {
    // Price is below range: position is 100% token0
    return { amount0: amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity), amount1: 0n }
  } else if (sqrtPrice >= sqrtUpper) {
    // Price is above range: position is 100% token1
    return { amount0: 0n, amount1: amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity) }
  } else {
    // Price is within range: split between token0 and token1
    return {
      amount0: amount0ForLiquidity(sqrtPrice, sqrtUpper, liquidity),
      amount1: amount1ForLiquidity(sqrtLower, sqrtPrice, liquidity),
    }
  }
}

// Decode sqrtPriceX96 from the raw bytes32 returned by PoolManager.extsload(slot0)
export function decodeSqrtPrice(raw: `0x${string}`): bigint {
  const n = BigInt(raw)
  return n & ((1n << 160n) - 1n) // lower 160 bits
}
