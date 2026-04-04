// Port of Uniswap v4 LiquidityAmounts.sol — same math, pure TypeScript bigint

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

// Decode sqrtPriceX96 from the raw bytes32 returned by PoolManager.extsload(slot0)
export function decodeSqrtPrice(raw: `0x${string}`): bigint {
  const n = BigInt(raw)
  return n & ((1n << 160n) - 1n) // lower 160 bits
}
