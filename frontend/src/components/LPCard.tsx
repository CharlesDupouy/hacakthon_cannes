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

export default function LPCard({ onPositionAdded }: { onPositionAdded: () => void }) {
  const { address } = useAccount()
  const [amount0, setAmount0] = useState('')
  const [amount1, setAmount1] = useState('')
  const parsed0 = amount0 ? parseUnits(amount0, 6) : 0n
  const parsed1 = amount1 ? parseUnits(amount1, 6) : 0n

  // Read current pool sqrtPrice from PoolManager storage
  const { data: slot0Raw } = useReadContract({
    address: POOL_MANAGER_ADDRESS,
    abi: POOL_MANAGER_ABI,
    functionName: 'extsload',
    args: [POOL_SQRT_PRICE_SLOT],
  })

  const sqrtPrice = slot0Raw ? decodeSqrtPrice(slot0Raw) : 0n

  // Preview how many stata shares each amount wraps to
  const { data: preview0 } = useReadContract({
    address: STATA_USDC_ADDRESS,
    abi: ERC4626_ABI,
    functionName: 'previewDeposit',
    args: [parsed0],
    query: { enabled: parsed0 > 0n },
  })

  const { data: preview1 } = useReadContract({
    address: STATA_USDT_ADDRESS,
    abi: ERC4626_ABI,
    functionName: 'previewDeposit',
    args: [parsed1],
    query: { enabled: parsed1 > 0n },
  })

  // Compute liquidity using the actual pool price (same formula as AddLiquidityV4.s.sol)
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

  return (
    <div className="bg-white rounded-2xl shadow p-6 w-full max-w-md border border-gray-100">
      <h2 className="text-xl font-semibold mb-4 text-gray-800">Add Liquidity</h2>

      <div className="mb-3">
        <label className="block text-sm text-gray-500 mb-1">USDC amount</label>
        <input type="number" min="0" placeholder="0.00" value={amount0}
          onChange={(e) => setAmount0(e.target.value)}
          className="w-full border border-gray-200 rounded-xl px-4 py-3 text-lg focus:outline-none focus:ring-2 focus:ring-indigo-400" />
        {preview0 !== undefined && parsed0 > 0n && (
          <p className="text-xs text-gray-400 mt-1">≈ {(Number(preview0) / 1e6).toFixed(4)} stataUSDC shares</p>
        )}
      </div>

      <div className="mb-4">
        <label className="block text-sm text-gray-500 mb-1">USDT amount</label>
        <input type="number" min="0" placeholder="0.00" value={amount1}
          onChange={(e) => setAmount1(e.target.value)}
          className="w-full border border-gray-200 rounded-xl px-4 py-3 text-lg focus:outline-none focus:ring-2 focus:ring-indigo-400" />
        {preview1 !== undefined && parsed1 > 0n && (
          <p className="text-xs text-gray-400 mt-1">≈ {(Number(preview1) / 1e6).toFixed(4)} stataUSDT shares</p>
        )}
      </div>

      {liquidity > 0n && (
        <div className="mb-4 bg-indigo-50 rounded-xl px-4 py-2 text-sm text-indigo-700">
          Liquidity units: <strong>{liquidity.toString()}</strong>
          {sqrtPrice > 0n && (
            <span className="ml-2 text-xs text-indigo-400">
              (pool price: {((Number(sqrtPrice) / 2 ** 96) ** 2).toFixed(4)})
            </span>
          )}
        </div>
      )}

      {!address ? (
        <p className="text-center text-gray-400 text-sm">Connect your wallet to add liquidity</p>
      ) : (
        <div className="space-y-2">
          {needsApproval0 && (
            <button onClick={() => approve0({ address: USDC_ADDRESS, abi: ERC20_ABI, functionName: 'approve', args: [YIELD_HOOK_ADDRESS, maxUint256] })}
              disabled={approveLoading0}
              className="w-full bg-indigo-400 hover:bg-indigo-500 disabled:opacity-50 text-white font-semibold py-3 rounded-xl transition">
              {approveLoading0 ? 'Approving...' : 'Approve USDC'}
            </button>
          )}
          {needsApproval1 && (
            <button onClick={() => approve1({ address: USDT_ADDRESS, abi: ERC20_ABI, functionName: 'approve', args: [YIELD_HOOK_ADDRESS, maxUint256] })}
              disabled={approveLoading1}
              className="w-full bg-indigo-400 hover:bg-indigo-500 disabled:opacity-50 text-white font-semibold py-3 rounded-xl transition">
              {approveLoading1 ? 'Approving...' : 'Approve USDT'}
            </button>
          )}
          <button
            onClick={() => addLiquidity({ address: YIELD_HOOK_ADDRESS, abi: YIELD_HOOK_ABI, functionName: 'addLiquidity', args: [parsed0, parsed1, TICK_LOWER, TICK_UPPER, liquidity] })}
            disabled={!canAdd || addLoading || addConfirming}
            className="w-full bg-indigo-500 hover:bg-indigo-600 disabled:opacity-50 text-white font-semibold py-3 rounded-xl transition">
            {addLoading || addConfirming ? 'Adding...' : 'Add Liquidity'}
          </button>
        </div>
      )}

      {addTxHash && (
        <div className="mt-4 text-sm text-center">
          <a href={`https://sepolia.basescan.org/tx/${addTxHash}`} target="_blank" rel="noreferrer"
            className="text-indigo-500 underline break-all">
            {addSuccess ? '✓ Liquidity added' : 'View on BaseScan'}: {addTxHash.slice(0, 20)}...
          </a>
        </div>
      )}
    </div>
  )
}
