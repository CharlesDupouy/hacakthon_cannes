import { useState, useEffect, useCallback } from 'react'
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseUnits, maxUint256 } from 'viem'
import { YIELD_HOOK_ADDRESS, USDC_ADDRESS, UNISWAP_API_BASE, MAINNET_USDC, MAINNET_USDT } from '../constants'
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
  const [quote, setQuote] = useState<string | null>(null)
  const [quoteLoading, setQuoteLoading] = useState(false)
  const [quoteError, setQuoteError] = useState<string | null>(null)

  const parsedAmount = amountIn ? parseUnits(amountIn, 6) : 0n

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: USDC_ADDRESS,
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

  const fetchQuote = useCallback(
    debounce(async (amount: string) => {
      if (!amount || parseFloat(amount) <= 0) {
        setQuote(null)
        return
      }
      setQuoteLoading(true)
      setQuoteError(null)
      try {
        const raw = parseUnits(amount, 6).toString()
        const res = await fetch(`${UNISWAP_API_BASE}/quote`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': import.meta.env.VITE_UNISWAP_API_KEY ?? '',
          },
          body: JSON.stringify({
            tokenIn: MAINNET_USDC,
            tokenInChainId: 1,
            tokenOut: MAINNET_USDT,
            tokenOutChainId: 1,
            amount: raw,
            type: 'EXACT_INPUT',
            protocols: ['V2', 'V3', 'V4'],
          }),
        })
        if (!res.ok) throw new Error(`API error ${res.status}`)
        const data = await res.json()
        const outAmount = data?.quote?.output?.amount ?? data?.quoteDecimals ?? null
        if (outAmount) {
          setQuote(parseFloat(outAmount).toFixed(4))
        } else {
          setQuote(null)
          setQuoteError('No route found')
        }
      } catch (e) {
        setQuoteError('Failed to fetch quote')
      } finally {
        setQuoteLoading(false)
      }
    }, 500),
    [],
  )

  useEffect(() => {
    fetchQuote(amountIn)
  }, [amountIn, fetchQuote])

  const needsApproval = allowance !== undefined && parsedAmount > 0n && allowance < parsedAmount

  function handleApprove() {
    approve({
      address: USDC_ADDRESS,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [YIELD_HOOK_ADDRESS, maxUint256],
    })
  }

  function handleSwap() {
    if (!parsedAmount) return
    swap({
      address: YIELD_HOOK_ADDRESS,
      abi: YIELD_HOOK_ABI,
      functionName: 'swap',
      args: [USDC_ADDRESS, parsedAmount, 0n],
    })
  }

  return (
    <div className="bg-white rounded-2xl shadow p-6 w-full max-w-md mx-auto border border-gray-100">
      <h2 className="text-xl font-semibold mb-4 text-gray-800">Swap USDC → USDT</h2>

      <div className="mb-4">
        <label className="block text-sm text-gray-500 mb-1">You pay (USDC)</label>
        <input
          type="number"
          min="0"
          placeholder="0.00"
          value={amountIn}
          onChange={(e) => setAmountIn(e.target.value)}
          className="w-full border border-gray-200 rounded-xl px-4 py-3 text-lg focus:outline-none focus:ring-2 focus:ring-pink-400"
        />
      </div>

      <div className="mb-4 rounded-xl bg-gray-50 px-4 py-3 text-sm text-gray-600 min-h-[48px] flex items-center">
        {quoteLoading ? (
          <span className="text-gray-400">Fetching quote...</span>
        ) : quoteError ? (
          <span className="text-red-400">{quoteError}</span>
        ) : quote && amountIn ? (
          <span>
            Reference rate: <strong>{amountIn} USDC ≈ {quote} USDT</strong>
          </span>
        ) : (
          <span className="text-gray-400">Enter an amount to see a quote</span>
        )}
        <span className="ml-auto text-xs text-gray-400">Uniswap Trading API (mainnet)</span>
      </div>

      {!address ? (
        <p className="text-center text-gray-400 text-sm">Connect your wallet to swap</p>
      ) : needsApproval ? (
        <button
          onClick={handleApprove}
          disabled={approveLoading}
          className="w-full bg-pink-500 hover:bg-pink-600 disabled:opacity-50 text-white font-semibold py-3 rounded-xl transition"
        >
          {approveLoading ? 'Approving...' : 'Approve USDC'}
        </button>
      ) : (
        <button
          onClick={handleSwap}
          disabled={swapLoading || swapConfirming || !parsedAmount}
          className="w-full bg-pink-500 hover:bg-pink-600 disabled:opacity-50 text-white font-semibold py-3 rounded-xl transition"
        >
          {swapLoading || swapConfirming ? 'Swapping...' : 'Swap'}
        </button>
      )}

      {swapTxHash && (
        <div className="mt-4 text-sm text-center">
          <a
            href={`https://sepolia.basescan.org/tx/${swapTxHash}`}
            target="_blank"
            rel="noreferrer"
            className="text-pink-500 underline break-all"
          >
            {swapSuccess ? '✓ Swap confirmed' : 'View on BaseScan'}: {swapTxHash.slice(0, 20)}...
          </a>
        </div>
      )}

      <p className="mt-4 text-xs text-center text-gray-400">
        Powered by Uniswap Trading API · Actual swap executes on Base Sepolia via YieldHook
      </p>
    </div>
  )
}
