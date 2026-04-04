import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { YIELD_HOOK_ADDRESS } from '../constants'
import { YIELD_HOOK_ABI } from '../abis'

const USDC_ICON = 'https://lh3.googleusercontent.com/aida-public/AB6AXuAEAJdLqxZG5z3bqaXHN5UbP7E0epqScDq9S13aOtI6llsaAjpS4sgRJqoUqJSZFuPiHl0vRtaY1km94e0karz4kFX9Y_Wg9q_JpYgtvL_TvJycGVXIR0Zs-GVbKHtMtSVzcsIWFd1THzyRVEF7LG9U8wcgb-_bumebpW5herlM4TMsxIkeJFOxWNvd_j6RSSnBbbCX8FNe4z5hZIy-v5bLLzSTeXpuFn0l6LVI6Q1ZrMDU2m2DZPpNBi7IlePrBNbKvJoPZLLUyDmw'
const USDT_ICON = 'https://lh3.googleusercontent.com/aida-public/AB6AXuAxkTgdMAEkzmEXhJYzfWONzVLKbo02xNIPoKFdXx-PlBeRRhfMt_13iMKS3_lhr7iROtqNPGbU0eZwLglsmmuqtX7z7zFQrHA4Ab0pesjMb5LWL51R5AXhIU31hMcfQgb_shUfezg7m56EHTPB1MsTmEChNGEM2GbWlm04j0q4k0y3tahqQTXDtRQARe4vx7v4b35_tm6668EnvoElTQNVAMbSDV_wsVEOxkPnYPvGjhORU4TqOW-NZVAFfs3Oldz7xWV6KgB_6eZK'

function PositionRow({ positionId, onRemoved }: { positionId: bigint; onRemoved: () => void }) {
  const { data: position } = useReadContract({
    address: YIELD_HOOK_ADDRESS, abi: YIELD_HOOK_ABI,
    functionName: 'getPosition', args: [positionId],
  })

  const { writeContract: removeLiquidity, data: removeTxHash, isPending: removeLoading } = useWriteContract()
  const { isSuccess: removeSuccess } = useWaitForTransactionReceipt({ hash: removeTxHash })

  if (removeSuccess) { onRemoved(); return null }

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
          {removeTxHash && !removeSuccess && (
            <a href={`https://sepolia.basescan.org/tx/${removeTxHash}`} target="_blank" rel="noreferrer"
              className="text-[10px] text-secondary underline font-label">
              Pending tx...
            </a>
          )}
        </div>
        <button
          onClick={() => removeLiquidity({ address: YIELD_HOOK_ADDRESS, abi: YIELD_HOOK_ABI, functionName: 'removeLiquidity', args: [positionId] })}
          disabled={removeLoading}
          className="px-5 py-2 rounded-full border border-error-dim/40 text-error-dim text-xs font-label hover:bg-error-container/10 transition-all disabled:opacity-50"
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
