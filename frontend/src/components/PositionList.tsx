import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import {
  YIELD_HOOK_ADDRESS, STATA_USDC_ADDRESS, STATA_USDT_ADDRESS,
  POOL_MANAGER_ADDRESS, POOL_SQRT_PRICE_SLOT,
  SQRT_PRICE_LOWER, SQRT_PRICE_UPPER,
} from '../constants'
import { YIELD_HOOK_ABI, ERC4626_ABI, POOL_MANAGER_ABI } from '../abis'
import { getAmountsForLiquidity, decodeSqrtPrice } from '../liquidityMath'

const USDC_ICON = 'https://lh3.googleusercontent.com/aida-public/AB6AXuAEAJdLqxZG5z3bqaXHN5UbP7E0epqScDq9S13aOtI6llsaAjpS4sgRJqoUqJSZFuPiHl0vRtaY1km94e0karz4kFX9Y_Wg9q_JpYgtvL_TvJycGVXIR0Zs-GVbKHtMtSVzcsIWFd1THzyRVEF7LG9U8wcgb-_bumebpW5herlM4TMsxIkeJFOxWNvd_j6RSSnBbbCX8FNe4z5hZIy-v5bLLzSTeXpuFn0l6LVI6Q1ZrMDU2m2DZPpNBi7IlePrBNbKvJoPZLLUyDmw'
const USDT_ICON = 'https://lh3.googleusercontent.com/aida-public/AB6AXuAxkTgdMAEkzmEXhJYzfWONzVLKbo02xNIPoKFdXx-PlBeRRhfMt_13iMKS3_lhr7iROtqNPGbU0eZwLglsmmuqtX7z7zFQrHA4Ab0pesjMb5LWL51R5AXhIU31hMcfQgb_shUfezg7m56EHTPB1MsTmEChNGEM2GbWlm04j0q4k0y3tahqQTXDtRQARe4vx7v4b35_tm6668EnvoElTQNVAMbSDV_wsVEOxkPnYPvGjhORU4TqOW-NZVAFfs3Oldz7xWV6KgB_6eZK'

function PositionRow({ positionId, onRemoved }: { positionId: bigint; onRemoved: () => void }) {
  const { data: position } = useReadContract({
    address: YIELD_HOOK_ADDRESS, abi: YIELD_HOOK_ABI,
    functionName: 'getPosition', args: [positionId],
  })

  // ── Estimate what you'd receive if you removed now ──────────────────────────
  //
  // Step 1: read the current pool sqrtPrice via PoolManager.extsload(slot0)
  const { data: slot0Raw } = useReadContract({
    address: POOL_MANAGER_ADDRESS, abi: POOL_MANAGER_ABI,
    functionName: 'extsload', args: [POOL_SQRT_PRICE_SLOT],
  })
  const sqrtPrice = slot0Raw ? decodeSqrtPrice(slot0Raw) : 0n

  // Step 2: compute stataToken amounts using getAmountsForLiquidity
  // This is the exact inverse of getLiquidityForAmounts (same Uniswap formula).
  // Returns stataUSDC shares and stataUSDT shares Uniswap would release.
  // NOTE: principal only — swap fees are not included (require feeGrowthInside reads).
  const liquidity = position?.liquidity ?? 0n
  const { amount0: stataAmt0, amount1: stataAmt1 } =
    sqrtPrice > 0n && liquidity > 0n
      ? getAmountsForLiquidity(sqrtPrice, SQRT_PRICE_LOWER, SQRT_PRICE_UPPER, liquidity)
      : { amount0: 0n, amount1: 0n }

  // Step 3: convert current stata shares → underlying USDC/USDT via previewRedeem
  // previewRedeem(shares) returns assets at current Aave redemption rate.
  // This is where Aave yield is captured: rate has grown since deposit.
  const { data: usdc0 } = useReadContract({
    address: STATA_USDC_ADDRESS, abi: ERC4626_ABI, functionName: 'previewRedeem',
    args: [stataAmt0], query: { enabled: stataAmt0 > 0n },
  })
  const { data: usdt1 } = useReadContract({
    address: STATA_USDT_ADDRESS, abi: ERC4626_ABI, functionName: 'previewRedeem',
    args: [stataAmt1], query: { enabled: stataAmt1 > 0n },
  })

  // Step 4: convert original deposited stata shares → USDC/USDT at current rate
  // stataDeposited0/1 are the exact shares Uniswap consumed at deposit time.
  // previewRedeem on them now gives what the original deposit would be worth today
  // if it had just sat in Aave — isolating the pure Aave yield component.
  // P&L = currentValue - depositValueAtCurrentRate
  //   > 0: gained (fees + favorable price movement)
  //   < 0: impermanent loss exceeded fees+yield
  const stataDeposited0 = position?.stataDeposited0 ?? 0n
  const stataDeposited1 = position?.stataDeposited1 ?? 0n
  const { data: depositUsdc0 } = useReadContract({
    address: STATA_USDC_ADDRESS, abi: ERC4626_ABI, functionName: 'previewRedeem',
    args: [stataDeposited0], query: { enabled: stataDeposited0 > 0n },
  })
  const { data: depositUsdt1 } = useReadContract({
    address: STATA_USDT_ADDRESS, abi: ERC4626_ABI, functionName: 'previewRedeem',
    args: [stataDeposited1], query: { enabled: stataDeposited1 > 0n },
  })

  const estUsdc = usdc0 !== undefined ? (Number(usdc0) / 1e6).toFixed(4) : null
  const estUsdt = usdt1 !== undefined ? (Number(usdt1) / 1e6).toFixed(4) : null
  const hasEstimate = estUsdc !== null || estUsdt !== null

  // P&L: compare current underlying value vs deposited underlying value at current Aave rate.
  // Both are in USDC/USDT (6 decimals). We sum across both tokens.
  const depositTotal =
    depositUsdc0 !== undefined && depositUsdt1 !== undefined
      ? Number(depositUsdc0 + depositUsdt1)
      : null
  const currentTotal =
    usdc0 !== undefined && usdt1 !== undefined
      ? Number(usdc0 + usdt1)
      : null
  const pnlPct =
    depositTotal !== null && currentTotal !== null && depositTotal > 0
      ? ((currentTotal - depositTotal) / depositTotal) * 100
      : null
  const pnlPositive = pnlPct !== null && pnlPct >= 0

  // ──────────────────────────────────────────────────────────────────────────

  const { writeContract: removeLiquidity, data: removeTxHash, isPending: removeLoading } = useWriteContract()
  const { isSuccess: removeSuccess } = useWaitForTransactionReceipt({ hash: removeTxHash })

  if (removeSuccess) { onRemoved(); return null }

  // Position was previously removed (liquidity set to 0 by the hook) but the
  // ID is still in the user's array on-chain. Skip rendering it — attempting
  // to remove a 0-liquidity position calls modifyLiquidity(delta=0) which reverts.
  if (position && position.liquidity === 0n) return null

  return (
    <div className="bg-surface-container-high/30 p-6 rounded-lg ghost-border hover:bg-surface-container-high/50 transition-all group">
      <div className="flex justify-between items-start mb-6">
        <div className="flex items-center gap-2">
          <div className="flex -space-x-2">
            <img src={USDC_ICON} className="w-6 h-6 rounded-full border-2 border-surface-container-high" alt="USDC"
              onError={(e) => { (e.target as HTMLImageElement).style.display='none' }} />
            <img src={USDT_ICON} className="w-6 h-6 rounded-full border-2 border-surface-container-high" alt="USDT"
              onError={(e) => { (e.target as HTMLImageElement).style.display='none' }} />
          </div>
          <span className="font-label font-bold text-sm">USDC/USDT</span>
        </div>
        <span className="bg-secondary-container/20 text-secondary text-[10px] font-label px-2 py-0.5 rounded-full border border-secondary/20">
          0.05% TIER
        </span>
      </div>

      <div className="flex justify-between items-end">
        <div>
          <p className="text-[10px] text-outline font-label uppercase tracking-tighter mb-1">Liquidity Units</p>
          <p className="text-xl font-label font-bold text-on-surface">
            {position ? Number(position.liquidity).toLocaleString() : '...'}
          </p>
          <p className="text-[10px] text-outline font-label mt-1">Position #{positionId.toString()}</p>

          {/* Estimated receive + P&L on removal */}
          {hasEstimate && (
            <div className="mt-3 bg-surface-container-low/60 rounded-md px-3 py-2 border border-outline-variant/10 space-y-2">
              <div>
                <p className="text-[10px] text-outline font-label uppercase tracking-tighter mb-1">Est. receive</p>
                <p className="text-sm font-label font-bold text-secondary">
                  {estUsdc ?? '—'} USDC + {estUsdt ?? '—'} USDT
                </p>
              </div>
              {pnlPct !== null && (
                <div className="border-t border-outline-variant/10 pt-2">
                  <p className="text-[10px] text-outline font-label uppercase tracking-tighter mb-1">P&amp;L</p>
                  <p className={`text-sm font-label font-bold ${pnlPositive ? 'text-emerald-400' : 'text-error-dim'}`}>
                    {pnlPositive ? '+' : ''}{pnlPct.toFixed(2)}%
                  </p>
                </div>
              )}
              <p className="text-[9px] text-outline/60 font-label">excl. swap fees · vs original deposit at current Aave rate</p>
            </div>
          )}

          {removeTxHash && !removeSuccess && (
            <a href={`https://sepolia.basescan.org/tx/${removeTxHash}`} target="_blank" rel="noreferrer"
              className="text-[10px] text-secondary underline font-label mt-2 block">
              Pending tx...
            </a>
          )}
        </div>
        <button
          onClick={() => removeLiquidity({ address: YIELD_HOOK_ADDRESS, abi: YIELD_HOOK_ABI, functionName: 'removeLiquidity', args: [positionId] })}
          disabled={removeLoading}
          className="px-5 py-2 rounded-full border border-error-dim/40 text-error-dim text-xs font-label hover:bg-error-container/10 transition-all disabled:opacity-50 self-end"
        >
          {removeLoading ? 'Removing...' : 'Remove'}
        </button>
      </div>
    </div>
  )
}

export default function PositionList({ refreshKey: _refreshKey }: { refreshKey: number }) {
  const { address } = useAccount()

  const { data: positionIds, refetch } = useReadContract({
    address: YIELD_HOOK_ADDRESS, abi: YIELD_HOOK_ABI,
    functionName: 'getUserPositions', args: [address!],
    query: { enabled: !!address },
  })

  return (
    <div className="glass-card ghost-border rounded-lg p-8">
      <div className="flex justify-between items-baseline mb-10">
        <h2 className="font-headline font-bold text-2xl">My Positions</h2>
        <span className="font-label text-xs text-outline tracking-widest uppercase">Active</span>
      </div>

      {!address ? (
        <p className="text-on-surface-variant text-sm font-label text-center py-8">Connect your wallet to view positions</p>
      ) : !positionIds || positionIds.length === 0 ? (
        <div className="space-y-4">
          <div className="p-8 border-2 border-dashed border-outline-variant/20 rounded-lg flex flex-col items-center justify-center text-center opacity-40">
            <span className="material-symbols-outlined text-4xl mb-2 text-outline">add_circle</span>
            <p className="font-label text-xs">No positions yet</p>
            <p className="font-label text-xs text-outline mt-1">Add liquidity to get started</p>
          </div>
        </div>
      ) : (
        <div className="space-y-4">
          {positionIds.map((id) => (
            <PositionRow key={id.toString()} positionId={id} onRemoved={() => refetch()} />
          ))}
          <div className="p-6 border-2 border-dashed border-outline-variant/20 rounded-lg flex flex-col items-center justify-center text-center opacity-40">
            <span className="material-symbols-outlined text-3xl mb-2 text-outline">add_circle</span>
            <p className="font-label text-xs">Add another position</p>
          </div>
        </div>
      )}
    </div>
  )
}
