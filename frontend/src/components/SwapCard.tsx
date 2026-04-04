import { useState, useEffect, useCallback } from 'react'
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseUnits, maxUint256 } from 'viem'
import {
  YIELD_HOOK_ADDRESS, USDC_ADDRESS, USDT_ADDRESS,
  MAINNET_USDC, MAINNET_USDT,
} from '../constants'
import { YIELD_HOOK_ABI, ERC20_ABI } from '../abis'

function debounce<T extends (...args: Parameters<T>) => void>(fn: T, ms: number) {
  let timer: ReturnType<typeof setTimeout>
  return (...args: Parameters<T>) => {
    clearTimeout(timer)
    timer = setTimeout(() => fn(...args), ms)
  }
}

export default function SwapCard() {
  const { address } = useAccount()
  const [amountIn, setAmountIn] = useState('')
  const [reversed, setReversed] = useState(false) // false = USDC→USDT, true = USDT→USDC
  const [quote, setQuote] = useState<string | null>(null)
  const [quoteLoading, setQuoteLoading] = useState(false)
  const [quoteError, setQuoteError] = useState<string | null>(null)

  const tokenIn  = reversed ? USDT_ADDRESS : USDC_ADDRESS
  const labelIn  = reversed ? 'USDT' : 'USDC'
  const labelOut = reversed ? 'USDC' : 'USDT'

  const parsedAmount = amountIn ? parseUnits(amountIn, 6) : 0n

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: tokenIn,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: [address!, YIELD_HOOK_ADDRESS],
    query: { enabled: !!address },
  })

  const { writeContract: approve, data: approveTxHash, isPending: approveLoading } = useWriteContract()
  const { writeContract: swap, data: swapTxHash, isPending: swapLoading } = useWriteContract()

  const { isSuccess: approveSuccess } = useWaitForTransactionReceipt({ hash: approveTxHash })
  const { isSuccess: swapSuccess, isLoading: swapConfirming } = useWaitForTransactionReceipt({ hash: swapTxHash })

  useEffect(() => {
    if (approveSuccess) refetchAllowance()
  }, [approveSuccess, refetchAllowance])

  // Reset state when direction flips
  useEffect(() => {
    setQuote(null)
    setQuoteError(null)
  }, [reversed])

  const fetchQuote = useCallback(
    debounce(async (amount: string, isReversed: boolean, swapper: string | undefined) => {
      if (!amount || parseFloat(amount) <= 0) { setQuote(null); return }
      setQuoteLoading(true)
      setQuoteError(null)
      try {
        const raw = parseUnits(amount, 6).toString()
        const res = await fetch(`/api/uniswap/quote`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tokenIn:         isReversed ? MAINNET_USDT : MAINNET_USDC,
            tokenInChainId:  1,
            tokenOut:        isReversed ? MAINNET_USDC : MAINNET_USDT,
            tokenOutChainId: 1,
            amount:          raw,
            type:            'EXACT_INPUT',
            protocols:       ['V2', 'V3', 'V4'],
            swapper:         swapper ?? '0x0000000000000000000000000000000000000001',
          }),
        })
        const data = await res.json()
        if (!res.ok) throw new Error(data?.detail ?? data?.errorCode ?? `HTTP ${res.status}`)
        const outAmount = data?.quote?.output?.amount ?? data?.quoteDecimals ?? null
        if (outAmount) {
          setQuote((Number(outAmount) / 1e6).toFixed(4))
        } else {
          setQuoteError('No route found')
        }
      } catch (e: unknown) {
        setQuoteError(e instanceof Error ? e.message : 'Failed to fetch quote')
      } finally {
        setQuoteLoading(false)
      }
    }, 500),
    [],
  )

  useEffect(() => {
    fetchQuote(amountIn, reversed, address)
  }, [amountIn, reversed, address, fetchQuote])

  const needsApproval = allowance !== undefined && parsedAmount > 0n && allowance < parsedAmount

  function handleApprove() {
    approve({ address: tokenIn, abi: ERC20_ABI, functionName: 'approve', args: [YIELD_HOOK_ADDRESS, maxUint256] })
  }

  function handleSwap() {
    if (!parsedAmount) return
    swap({ address: YIELD_HOOK_ADDRESS, abi: YIELD_HOOK_ABI, functionName: 'swap', args: [tokenIn, parsedAmount, 0n] })
  }

  return (
    <div className="bg-white rounded-2xl shadow p-6 w-full max-w-md mx-auto border border-gray-100">
      <h2 className="text-xl font-semibold mb-4 text-gray-800">Swap</h2>

      {/* Input */}
      <div className="mb-2">
        <label className="block text-sm text-gray-500 mb-1">You pay ({labelIn})</label>
        <input
          type="number" min="0" placeholder="0.00" value={amountIn}
          onChange={(e) => setAmountIn(e.target.value)}
          className="w-full border border-gray-200 rounded-xl px-4 py-3 text-lg focus:outline-none focus:ring-2 focus:ring-pink-400"
        />
      </div>

      {/* Direction toggle */}
      <div className="flex justify-center my-3">
        <button
          onClick={() => { setReversed(r => !r); setAmountIn('') }}
          className="bg-gray-100 hover:bg-gray-200 rounded-full p-2 transition"
          title="Flip direction"
        >
          <svg className="w-5 h-5 text-gray-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2}
              d="M7 16V4m0 0L3 8m4-4l4 4M17 8v12m0 0l4-4m-4 4l-4-4" />
          </svg>
        </button>
      </div>

      {/* Output / quote */}
      <div className="mb-4 rounded-xl bg-gray-50 px-4 py-3 text-sm text-gray-600 min-h-[48px] flex items-center">
        {quoteLoading ? (
          <span className="text-gray-400">Fetching quote...</span>
        ) : quoteError ? (
          <span className="text-red-400">{quoteError}</span>
        ) : quote && amountIn ? (
          <span>You receive ≈ <strong>{quote} {labelOut}</strong></span>
        ) : (
          <span className="text-gray-400">You receive ({labelOut})</span>
        )}
        <span className="ml-auto text-xs text-gray-400">Uniswap API (mainnet ref.)</span>
      </div>

      {!address ? (
        <p className="text-center text-gray-400 text-sm">Connect your wallet to swap</p>
      ) : needsApproval ? (
        <button onClick={handleApprove} disabled={approveLoading}
          className="w-full bg-pink-500 hover:bg-pink-600 disabled:opacity-50 text-white font-semibold py-3 rounded-xl transition">
          {approveLoading ? 'Approving...' : `Approve ${labelIn}`}
        </button>
      ) : (
        <button onClick={handleSwap} disabled={swapLoading || swapConfirming || !parsedAmount}
          className="w-full bg-pink-500 hover:bg-pink-600 disabled:opacity-50 text-white font-semibold py-3 rounded-xl transition">
          {swapLoading || swapConfirming ? 'Swapping...' : `Swap ${labelIn} → ${labelOut}`}
        </button>
      )}

      {swapTxHash && (
        <div className="mt-4 text-sm text-center">
          <a href={`https://sepolia.basescan.org/tx/${swapTxHash}`} target="_blank" rel="noreferrer"
            className="text-pink-500 underline break-all">
            {swapSuccess ? '✓ Swap confirmed' : 'View on BaseScan'}: {swapTxHash.slice(0, 20)}...
          </a>
        </div>
      )}

      <p className="mt-4 text-xs text-center text-gray-400">
        Powered by Uniswap Trading API · Executes on Base Sepolia via YieldHook
      </p>
    </div>
  )
}
