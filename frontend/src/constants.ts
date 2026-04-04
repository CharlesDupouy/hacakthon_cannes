export const YIELD_HOOK_ADDRESS = '0xBdF688ee8034C64B8f75ddEBf4468634586FD000' as const
export const USDC_ADDRESS = '0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f' as const
export const USDT_ADDRESS = '0x0a215D8ba66387DCA84B284D18c3B4ec3de6E54a' as const
export const STATA_USDC_ADDRESS = '0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a' as const
export const STATA_USDT_ADDRESS = '0xf63dA51069FAe9448747FA425F8Cb84B0149eC0F' as const
export const POOL_MANAGER_ADDRESS = '0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408' as const

export const TICK_LOWER = -887270
export const TICK_UPPER = 887270

// sqrtPrice at our tick bounds (from TickMath.getSqrtPriceAtTick)
export const SQRT_PRICE_LOWER = 4295558252n
export const SQRT_PRICE_UPPER = 1461300573427867316570072651998408279850435624081n

// Storage slot for the pool's slot0 in PoolManager
// = keccak256(poolId ++ uint256(6))  where 6 = POOLS_SLOT in StateLibrary
export const POOL_SQRT_PRICE_SLOT = '0xc32179839d20006a26254d94cf46767f517849a4a8c8f033ee902576d63d2d12' as const

export const MAINNET_USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48' as const
export const MAINNET_USDT = '0xdAC17F958D2ee523a2206206994597C13D831ec7' as const

export const UNISWAP_API_BASE = 'https://trade-api.gateway.uniswap.org/v1'
