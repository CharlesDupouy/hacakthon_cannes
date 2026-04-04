import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { YIELD_HOOK_ADDRESS } from '../constants'
import { YIELD_HOOK_ABI } from '../abis'

function PositionRow({ positionId, onRemoved }: { positionId: bigint; onRemoved: () => void }) {
  const { data: position } = useReadContract({
    address: YIELD_HOOK_ADDRESS,
    abi: YIELD_HOOK_ABI,
    functionName: 'getPosition',
    args: [positionId],
  })

  const { writeContract: removeLiquidity, data: removeTxHash, isPending: removeLoading } = useWriteContract()
  const { isSuccess: removeSuccess } = useWaitForTransactionReceipt({ hash: removeTxHash })

  if (removeSuccess) {
    onRemoved()
    return null
  }

  return (
    <div className="bg-gray-50 rounded-xl p-4 flex items-center justify-between gap-4">
      <div className="text-sm">
        <p className="font-semibold text-gray-700">Position #{positionId.toString()}</p>
        {position && (
          <p className="text-gray-500 text-xs mt-1">
            Liquidity: {position.liquidity.toString()} · Ticks: [{position.tickLower}, {position.tickUpper}]
          </p>
        )}
        {removeTxHash && !removeSuccess && (
          <a
            href={`https://sepolia.basescan.org/tx/${removeTxHash}`}
            target="_blank"
            rel="noreferrer"
            className="text-indigo-500 underline text-xs"
          >
            View tx...
          </a>
        )}
      </div>
      <button
        onClick={() =>
          removeLiquidity({
            address: YIELD_HOOK_ADDRESS,
            abi: YIELD_HOOK_ABI,
            functionName: 'removeLiquidity',
            args: [positionId],
          })
        }
        disabled={removeLoading}
        className="bg-red-100 hover:bg-red-200 disabled:opacity-50 text-red-600 font-semibold px-4 py-2 rounded-xl text-sm transition"
      >
        {removeLoading ? 'Removing...' : 'Remove'}
      </button>
    </div>
  )
}

export default function PositionList({ refreshKey: _refreshKey }: { refreshKey: number }) {
  const { address } = useAccount()

  const { data: positionIds, refetch } = useReadContract({
    address: YIELD_HOOK_ADDRESS,
    abi: YIELD_HOOK_ABI,
    functionName: 'getUserPositions',
    args: [address!],
    query: { enabled: !!address },
  })

  if (!address) {
    return (
      <div className="bg-white rounded-2xl shadow p-6 w-full max-w-md border border-gray-100">
        <h2 className="text-xl font-semibold mb-4 text-gray-800">My Positions</h2>
        <p className="text-gray-400 text-sm text-center">Connect your wallet to view positions</p>
      </div>
    )
  }

  return (
    <div className="bg-white rounded-2xl shadow p-6 w-full max-w-md border border-gray-100">
      <h2 className="text-xl font-semibold mb-4 text-gray-800">My Positions</h2>
      {!positionIds || positionIds.length === 0 ? (
        <p className="text-gray-400 text-sm text-center">No active positions</p>
      ) : (
        <div className="space-y-3">
          {positionIds.map((id) => (
            <PositionRow key={id.toString()} positionId={id} onRemoved={() => refetch()} />
          ))}
        </div>
      )}
    </div>
  )
}
