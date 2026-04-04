import { useState, useEffect, useCallback } from 'react'
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseUnits, maxUint256 } from 'viem'
import { YIELD_HOOK_ADDRESS, USDC_ADDRESS, USDT_ADDRESS, MAINNET_USDC, MAINNET_USDT } from '../constants'
import { YIELD_HOOK_ABI, ERC20_ABI } from '../abis'

const USDC_ICON = 'https://lh3.googleusercontent.com/aida-public/AB6AXuB2tWR_3-e9hJaqkr_vVMxA8zAECECB3DgIVK5tjHkMdHajYlWjF_hdoKLIUdck4ZTwQ3-1W94PPSxQjtsx_LlOEeaO4Vh_VCgjDz8VR52uroATiP35erRcGeWiGBSCv6ZsHlUaSTM0Kd2hB4gDuxzvm8PTJoZh4UBd_PrVVSI88D0AyyOG3BIgiB88ElyRvjuEOoc68RgpecV34zWKM9JtBTzoAKG8yfQcTx4_AFxkdTrbwKB_cgFcd3bpvfLYrNdGVDBCTxR1dwRk'
const USDT_ICON = 'https://lh3.googleusercontent.com/aida-public/AB6AXuDK90M7p8oB_F_ecSy8U8wxvGDtVkITpeSqqm7LtzbLMeMtNHN-2FMV2gOlxNnet4BgtwGR1LxRLNBHsgaQzQSuefRPg31W10PzMHwF46aHrXTg8ja1uNKTahoMySlM9_Gydi7s1fItQK74ieRm6uJGRqauapD_lSvy6Laa1aJa2kyhNlostJnXtMmqd0XfGzJ7reRbRH_5H069M5A-q7qM_icaDzWy8MfpZmVij2EEZ1t8Q2ZKGURo8zzrJ8KrP2YWqB4KKUSPSOjD'

function debounce<T extends (...args: Parameters<T>) => void>(fn: T, ms: number) {
  let timer: ReturnType<typeof setTimeout>
  return (...args: Parameters<T>) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms) }
}

export default function SwapCard() {
  const { address } = useAccount()
  const [amountIn, setAmountIn] = useState('')
  const [reversed, setReversed] = useState(false)
  const [quote, setQuote] = useState<string | null>(null)
  const [quoteLoading, setQuoteLoading] = useState(false)
  const [quoteError, setQuoteError] = useState<string | null>(null)

  const tokenIn = reversed ? USDT_ADDRESS : USDC_ADDRESS
  const labelIn  = reversed ? 'USDT' : 'USDC'
  const labelOut = reversed ? 'USDC' : 'USDT'
  const iconIn   = reversed ? USDT_ICON : USDC_ICON
  const iconOut  = reversed ? USDC_ICON : USDT_ICON

  const parsedAmount = amountIn ? parseUnits(amountIn, 6) : 0n

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: tokenIn, abi: ERC20_ABI, functionName: 'allowance',
    args: [address!, YIELD_HOOK_ADDRESS], query: { enabled: !!address },
  })

  const { writeContract: approve, data: approveTxHash, isPending: approveLoading } = useWriteContract()
  const { writeContract: swap, data: swapTxHash, isPending: swapLoading } = useWriteContract()
  const { isSuccess: approveSuccess } = useWaitForTransactionReceipt({ hash: approveTxHash })
  const { isSuccess: swapSuccess, isLoading: swapConfirming } = useWaitForTransactionReceipt({ hash: swapTxHash })

  useEffect(() => { if (approveSuccess) refetchAllowance() }, [approveSuccess, refetchAllowance])
  useEffect(() => { setQuote(null); setQuoteError(null) }, [reversed])

  const fetchQuote = useCallback(
    debounce(async (amount: string, isReversed: boolean, swapper: string | undefined) => {
      if (!amount || parseFloat(amount) <= 0) { setQuote(null); return }
      setQuoteLoading(true); setQuoteError(null)
      try {
        const raw = parseUnits(amount, 6).toString()
        const res = await fetch('/api/uniswap/quote', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tokenIn: isReversed ? MAINNET_USDT : MAINNET_USDC,
            tokenInChainId: 1,
            tokenOut: isReversed ? MAINNET_USDC : MAINNET_USDT,
            tokenOutChainId: 1,
            amount: raw, type: 'EXACT_INPUT', protocols: ['V2', 'V3', 'V4'],
            swapper: swapper ?? '0x0000000000000000000000000000000000000001',
          }),
        })
        const data = await res.json()
        if (!res.ok) throw new Error(data?.detail ?? data?.errorCode ?? `HTTP ${res.status}`)
        const outAmount = data?.quote?.output?.amount ?? null
        if (outAmount) setQuote((Number(outAmount) / 1e6).toFixed(4))
        else setQuoteError('No route found')
      } catch (e: unknown) {
        setQuoteError(e instanceof Error ? e.message : 'Failed to fetch quote')
      } finally { setQuoteLoading(false) }
    }, 500), [],
  )

  useEffect(() => { fetchQuote(amountIn, reversed, address) }, [amountIn, reversed, address, fetchQuote])

  const needsApproval = allowance !== undefined && parsedAmount > 0n && allowance < parsedAmount

  return (
    <div className="glass-card ghost-border w-full max-w-[420px] rounded-xl p-6 relative">
      <div className="flex justify-between items-center mb-6">
        <h2 className="font-headline text-xl font-bold text-on-surface">Swap</h2>
      </div>

      {/* Pay */}
      <div className="bg-surface-container-highest/40 rounded-lg p-4 mb-2 border border-transparent focus-within:border-primary/20 transition-all">
        <div className="flex justify-between mb-2">
          <span className="text-xs font-label text-outline uppercase tracking-wider">You pay</span>
        </div>
        <div className="flex justify-between items-center gap-3">
          <input
            className="bg-transparent border-none focus:ring-0 text-3xl font-label w-full p-0 text-on-surface placeholder:text-surface-bright outline-none"
            placeholder="0" type="number" min="0" value={amountIn}
            onChange={(e) => setAmountIn(e.target.value)}
          />
          <div className="flex items-center gap-2 bg-surface-container-high px-3 py-1.5 rounded-full ghost-border shrink-0">
            <img src={iconIn} className="w-6 h-6 rounded-full" alt={labelIn} onError={(e) => { (e.target as HTMLImageElement).style.display='none' }} />
            <span className="font-label font-bold text-sm">{labelIn}</span>
          </div>
        </div>
      </div>

      {/* Direction toggle */}
      <div className="relative h-4 flex justify-center items-center z-10 my-1">
        <button
          onClick={() => { setReversed(r => !r); setAmountIn('') }}
          className="absolute bg-surface-container-high border-4 border-background w-10 h-10 rounded-full flex items-center justify-center hover:scale-110 transition-transform shadow-xl group"
        >
          <span className="material-symbols-outlined text-primary group-hover:rotate-180 transition-transform duration-500">arrow_downward</span>
        </button>
      </div>

      {/* Receive */}
      <div className="bg-surface-container-highest/40 rounded-lg p-4 mt-2 mb-6">
        <div className="flex justify-between mb-2">
          <span className="text-xs font-label text-outline uppercase tracking-wider">You receive</span>
        </div>
        <div className="flex justify-between items-center gap-3">
          <div className="text-3xl font-label w-full text-outline">
            {quoteLoading ? (
              <span className="text-base text-outline/60 animate-pulse">fetching...</span>
            ) : quote && amountIn ? quote : '0'}
          </div>
          <div className="flex items-center gap-2 bg-surface-container-high px-3 py-1.5 rounded-full ghost-border shrink-0">
            <img src={iconOut} className="w-6 h-6 rounded-full" alt={labelOut} onError={(e) => { (e.target as HTMLImageElement).style.display='none' }} />
            <span className="font-label font-bold text-sm">{labelOut}</span>
          </div>
        </div>
      </div>

      {/* Rate info */}
      <div className="flex items-start gap-3 bg-surface-container-low/50 p-3 rounded-lg mb-6">
        <span className="material-symbols-outlined text-secondary text-sm mt-0.5">info</span>
        <div className="flex flex-col gap-1">
          {quoteError ? (
            <p className="text-[11px] text-error font-label">{quoteError}</p>
          ) : quote && amountIn ? (
            <p className="text-[11px] text-on-surface-variant font-label">
              Reference rate: <span className="text-on-surface">{amountIn} {labelIn} ≈ {quote} {labelOut}</span>
            </p>
          ) : (
            <p className="text-[11px] text-on-surface-variant font-label">Enter an amount to see a quote</p>
          )}
          <span className="text-[10px] text-outline">Powered by Uniswap Trading API (mainnet)</span>
        </div>
      </div>

      {/* Action */}
      {!address ? (
        <div className="w-full py-4 rounded-xl bg-surface-container-high text-outline text-center font-label text-sm">
          Connect your wallet to swap
        </div>
      ) : needsApproval ? (
        <button
          onClick={() => approve({ address: tokenIn, abi: ERC20_ABI, functionName: 'approve', args: [YIELD_HOOK_ADDRESS, maxUint256] })}
          disabled={approveLoading}
          className="w-full primary-gradient py-4 rounded-xl font-bold text-lg shadow-[0_8px_30px_rgba(138,76,252,0.2)] hover:shadow-[0_8px_40px_rgba(138,76,252,0.4)] transition-all active:scale-[0.98] disabled:opacity-50 font-headline"
        >
          {approveLoading ? 'Approving...' : `Approve ${labelIn}`}
        </button>
      ) : (
        <button
          onClick={() => { if (parsedAmount) swap({ address: YIELD_HOOK_ADDRESS, abi: YIELD_HOOK_ABI, functionName: 'swap', args: [tokenIn, parsedAmount, 0n] }) }}
          disabled={swapLoading || swapConfirming || !parsedAmount}
          className="w-full primary-gradient py-4 rounded-xl font-bold text-lg shadow-[0_8px_30px_rgba(138,76,252,0.2)] hover:shadow-[0_8px_40px_rgba(138,76,252,0.4)] transition-all active:scale-[0.98] disabled:opacity-50 font-headline"
        >
          {swapLoading || swapConfirming ? 'Swapping...' : `Swap ${labelIn} → ${labelOut}`}
        </button>
      )}

      {/* Tx confirmation */}
      {swapTxHash && (
        <div className="mt-4 flex items-center justify-center gap-2 p-2 bg-emerald-500/10 border border-emerald-500/20 rounded-lg">
          <span className="material-symbols-outlined text-emerald-500 text-sm" style={{ fontVariationSettings: "'FILL' 1" }}>check_circle</span>
          <span className="text-[11px] text-emerald-400 font-label">
            {swapSuccess ? 'Swap confirmed: ' : 'Pending: '}
            <a href={`https://sepolia.basescan.org/tx/${swapTxHash}`} target="_blank" rel="noreferrer" className="underline">
              {swapTxHash.slice(0, 10)}...{swapTxHash.slice(-4)}
            </a>
          </span>
        </div>
      )}
    </div>
  )
}
