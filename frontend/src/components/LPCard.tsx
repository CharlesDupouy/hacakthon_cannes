import { useState, useEffect } from 'react'
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseUnits, maxUint256 } from 'viem'
import {
  YIELD_HOOK_ADDRESS, USDC_ADDRESS, USDT_ADDRESS,
  STATA_USDC_ADDRESS, STATA_USDT_ADDRESS,
  POOL_MANAGER_ADDRESS, POOL_SQRT_PRICE_SLOT,
  TICK_LOWER, TICK_UPPER, SQRT_PRICE_LOWER, SQRT_PRICE_UPPER,
} from '../constants'
import { YIELD_HOOK_ABI, ERC20_ABI, ERC4626_ABI, POOL_MANAGER_ABI } from '../abis'
import { getLiquidityForAmounts, decodeSqrtPrice } from '../liquidityMath'

const USDC_ICON = 'https://lh3.googleusercontent.com/aida-public/AB6AXuB2tWR_3-e9hJaqkr_vVMxA8zAECECB3DgIVK5tjHkMdHajYlWjF_hdoKLIUdck4ZTwQ3-1W94PPSxQjtsx_LlOEeaO4Vh_VCgjDz8VR52uroATiP35erRcGeWiGBSCv6ZsHlUaSTM0Kd2hB4gDuxzvm8PTJoZh4UBd_PrVVSI88D0AyyOG3BIgiB88ElyRvjuEOoc68RgpecV34zWKM9JtBTzoAKG8yfQcTx4_AFxkdTrbwKB_cgFcd3bpvfLYrNdGVDBCTxR1dwRk'
const USDT_ICON = 'https://lh3.googleusercontent.com/aida-public/AB6AXuDK90M7p8oB_F_ecSy8U8wxvGDtVkITpeSqqm7LtzbLMeMtNHN-2FMV2gOlxNnet4BgtwGR1LxRLNBHsgaQzQSuefRPg31W10PzMHwF46aHrXTg8ja1uNKTahoMySlM9_Gydi7s1fItQK74ieRm6uJGRqauapD_lSvy6Laa1aJa2kyhNlostJnXtMmqd0XfGzJ7reRbRH_5H069M5A-q7qM_icaDzWy8MfpZmVij2EEZ1t8Q2ZKGURo8zzrJ8KrP2YWqB4KKUSPSOjD'

export default function LPCard({ onPositionAdded }: { onPositionAdded: () => void }) {
  const { address } = useAccount()
  const [amount0, setAmount0] = useState('')
  const [amount1, setAmount1] = useState('')
  const [lastEdited, setLastEdited] = useState<0 | 1>(0)
  const parsed0 = amount0 ? parseUnits(amount0, 6) : 0n
  const parsed1 = amount1 ? parseUnits(amount1, 6) : 0n

  const { data: slot0Raw } = useReadContract({
    address: POOL_MANAGER_ADDRESS, abi: POOL_MANAGER_ABI,
    functionName: 'extsload', args: [POOL_SQRT_PRICE_SLOT],
  })
  const sqrtPrice = slot0Raw ? decodeSqrtPrice(slot0Raw) : 0n

  useEffect(() => {
    if (sqrtPrice === 0n) return
    const price = (Number(sqrtPrice) / 2 ** 96) ** 2
    if (lastEdited === 0 && amount0) {
      const v = parseFloat(amount0)
      if (!isNaN(v) && v > 0) setAmount1((v * price).toFixed(6))
    } else if (lastEdited === 1 && amount1) {
      const v = parseFloat(amount1)
      if (!isNaN(v) && v > 0) setAmount0((v / price).toFixed(6))
    }
  }, [sqrtPrice, amount0, amount1, lastEdited])

  const { data: preview0 } = useReadContract({
    address: STATA_USDC_ADDRESS, abi: ERC4626_ABI, functionName: 'previewDeposit',
    args: [parsed0], query: { enabled: parsed0 > 0n },
  })
  const { data: preview1 } = useReadContract({
    address: STATA_USDT_ADDRESS, abi: ERC4626_ABI, functionName: 'previewDeposit',
    args: [parsed1], query: { enabled: parsed1 > 0n },
  })

  const liquidity: bigint =
    sqrtPrice > 0n && preview0 !== undefined && preview1 !== undefined
      ? getLiquidityForAmounts(sqrtPrice, SQRT_PRICE_LOWER, SQRT_PRICE_UPPER, preview0, preview1)
      : 0n

  const { data: allowance0, refetch: refetchAllowance0 } = useReadContract({
    address: USDC_ADDRESS, abi: ERC20_ABI, functionName: 'allowance',
    args: [address!, YIELD_HOOK_ADDRESS], query: { enabled: !!address },
  })
  const { data: allowance1, refetch: refetchAllowance1 } = useReadContract({
    address: USDT_ADDRESS, abi: ERC20_ABI, functionName: 'allowance',
    args: [address!, YIELD_HOOK_ADDRESS], query: { enabled: !!address },
  })

  const { writeContract: approve0, data: approveTx0, isPending: approveLoading0 } = useWriteContract()
  const { writeContract: approve1, data: approveTx1, isPending: approveLoading1 } = useWriteContract()
  const { writeContract: addLiquidity, data: addTxHash, isPending: addLoading } = useWriteContract()

  const { isSuccess: approve0Success } = useWaitForTransactionReceipt({ hash: approveTx0 })
  const { isSuccess: approve1Success } = useWaitForTransactionReceipt({ hash: approveTx1 })
  const { isSuccess: addSuccess, isLoading: addConfirming, data: addReceipt } = useWaitForTransactionReceipt({ hash: addTxHash })

  useEffect(() => { if (approve0Success) refetchAllowance0() }, [approve0Success, refetchAllowance0])
  useEffect(() => { if (approve1Success) refetchAllowance1() }, [approve1Success, refetchAllowance1])
  useEffect(() => { if (addSuccess && addReceipt) onPositionAdded() }, [addSuccess, addReceipt, onPositionAdded])

  const needsApproval0 = !!address && parsed0 > 0n && (allowance0 === undefined || allowance0 < parsed0)
  const needsApproval1 = !!address && parsed1 > 0n && (allowance1 === undefined || allowance1 < parsed1)
  const canAdd = !!address && !needsApproval0 && !needsApproval1 && parsed0 > 0n && parsed1 > 0n && liquidity > 0n

  const poolPrice = sqrtPrice > 0n ? ((Number(sqrtPrice) / 2 ** 96) ** 2).toFixed(4) : '—'

  return (
    <div className="glass-card ghost-border rounded-lg p-8 relative overflow-hidden">
      <div className="flex justify-between items-center mb-10">
        <h2 className="font-headline font-bold text-2xl">Add Liquidity</h2>
        <span className="material-symbols-outlined text-primary-dim cursor-pointer hover:rotate-180 transition-transform duration-500">settings</span>
      </div>

      {/* Input 0 — USDC */}
      <div className="space-y-2 mb-4">
        <div className="flex justify-between text-xs font-label text-outline px-1">
          <span>ASSET ONE</span>
        </div>
        <div className="bg-surface-container-highest/40 p-5 rounded-lg flex items-center justify-between focus-within:ring-1 ring-primary/30 transition-all">
          <input
            className="bg-transparent border-none focus:ring-0 text-3xl font-label w-full placeholder:text-surface-bright outline-none"
            placeholder="0.0" type="number" min="0" value={amount0}
            onChange={(e) => { setLastEdited(0); setAmount0(e.target.value) }}
          />
          <div className="flex items-center gap-3 bg-surface-container-high px-4 py-2 rounded-full ghost-border shrink-0">
            <img src={USDC_ICON} className="w-6 h-6 rounded-full" alt="USDC" onError={(e) => { (e.target as HTMLImageElement).style.display='none' }} />
            <span className="font-label font-bold tracking-wider">USDC</span>
          </div>
        </div>
        {preview0 !== undefined && parsed0 > 0n && (
          <p className="text-xs text-outline px-1">≈ {(Number(preview0) / 1e6).toFixed(4)} stataUSDC shares</p>
        )}
      </div>

      {/* Sync icon */}
      <div className="flex justify-center -my-1 relative z-10">
        <div className="bg-surface-container-high p-2 rounded-full ghost-border shadow-xl">
          <span className="material-symbols-outlined text-secondary text-sm">lock</span>
        </div>
      </div>

      {/* Input 1 — USDT */}
      <div className="space-y-2 mb-8 mt-4">
        <div className="flex justify-between text-xs font-label text-outline px-1">
          <span>ASSET TWO</span>
        </div>
        <div className="bg-surface-container-highest/40 p-5 rounded-lg flex items-center justify-between focus-within:ring-1 ring-primary/30 transition-all">
          <input
            className="bg-transparent border-none focus:ring-0 text-3xl font-label w-full placeholder:text-surface-bright outline-none"
            placeholder="0.0" type="number" min="0" value={amount1}
            onChange={(e) => { setLastEdited(1); setAmount1(e.target.value) }}
          />
          <div className="flex items-center gap-3 bg-surface-container-high px-4 py-2 rounded-full ghost-border shrink-0">
            <img src={USDT_ICON} className="w-6 h-6 rounded-full" alt="USDT" onError={(e) => { (e.target as HTMLImageElement).style.display='none' }} />
            <span className="font-label font-bold tracking-wider">USDT</span>
          </div>
        </div>
        {preview1 !== undefined && parsed1 > 0n && (
          <p className="text-xs text-outline px-1">≈ {(Number(preview1) / 1e6).toFixed(4)} stataUSDT shares</p>
        )}
      </div>

      {/* Pool info */}
      <div className="bg-surface-container-low/50 rounded-lg p-5 mb-8">
        <div className="flex flex-col gap-3 font-label text-sm">
          <div className="flex justify-between items-center">
            <span className="text-outline">Pool price:</span>
            <span className="text-on-surface">{poolPrice} USDT / USDC</span>
          </div>
          <div className="flex justify-between items-center">
            <span className="text-outline">Liquidity units:</span>
            <span className="text-secondary">{liquidity > 0n ? Number(liquidity).toLocaleString() : '—'}</span>
          </div>
          <div className="flex justify-between items-center">
            <span className="text-outline">Fee tier:</span>
            <span className="text-on-surface">0.05%</span>
          </div>
        </div>
      </div>

      {/* Buttons */}
      {!address ? (
        <div className="w-full py-4 rounded-full bg-surface-container-high text-outline text-center font-label text-sm">
          Connect your wallet to add liquidity
        </div>
      ) : (
        <div className="space-y-3">
          {(needsApproval0 || needsApproval1) && (
            <div className="grid grid-cols-2 gap-4">
              <button
                onClick={() => approve0({ address: USDC_ADDRESS, abi: ERC20_ABI, functionName: 'approve', args: [YIELD_HOOK_ADDRESS, maxUint256] })}
                disabled={approveLoading0 || !needsApproval0}
                className={`py-3 rounded-full font-headline font-bold text-sm transition-all active:scale-95 ${
                  needsApproval0
                    ? 'bg-surface-container-highest text-on-surface hover:text-primary'
                    : 'bg-surface-container text-outline/30 cursor-not-allowed'
                }`}
              >
                {approveLoading0 ? 'Approving...' : needsApproval0 ? 'Approve USDC' : '✓ USDC'}
              </button>
              <button
                onClick={() => approve1({ address: USDT_ADDRESS, abi: ERC20_ABI, functionName: 'approve', args: [YIELD_HOOK_ADDRESS, maxUint256] })}
                disabled={approveLoading1 || !needsApproval1}
                className={`py-3 rounded-full font-headline font-bold text-sm transition-all active:scale-95 ${
                  needsApproval1
                    ? 'bg-surface-container-highest text-on-surface hover:text-primary'
                    : 'bg-surface-container text-outline/30 cursor-not-allowed'
                }`}
              >
                {approveLoading1 ? 'Approving...' : needsApproval1 ? 'Approve USDT' : '✓ USDT'}
              </button>
            </div>
          )}
          <button
            onClick={() => addLiquidity({ address: YIELD_HOOK_ADDRESS, abi: YIELD_HOOK_ABI, functionName: 'addLiquidity', args: [parsed0, parsed1, TICK_LOWER, TICK_UPPER, liquidity] })}
            disabled={!canAdd || addLoading || addConfirming}
            className="w-full py-5 rounded-full primary-gradient text-on-primary-fixed font-headline font-extrabold text-lg shadow-[0_0_20px_rgba(189,157,255,0.3)] hover:shadow-[0_0_30px_rgba(189,157,255,0.5)] transition-all active:scale-[0.98] disabled:opacity-40"
          >
            {addLoading || addConfirming ? 'Adding...' : 'Add Liquidity'}
          </button>
        </div>
      )}

      {addTxHash && (
        <div className="mt-4 flex items-center justify-center gap-2 p-2 bg-emerald-500/10 border border-emerald-500/20 rounded-lg">
          <span className="material-symbols-outlined text-emerald-500 text-sm" style={{ fontVariationSettings: "'FILL' 1" }}>check_circle</span>
          <span className="text-[11px] text-emerald-400 font-label">
            {addSuccess ? 'Liquidity added: ' : 'Pending: '}
            <a href={`https://sepolia.basescan.org/tx/${addTxHash}`} target="_blank" rel="noreferrer" className="underline">
              {addTxHash.slice(0, 10)}...{addTxHash.slice(-4)}
            </a>
          </span>
        </div>
      )}
    </div>
  )
}
