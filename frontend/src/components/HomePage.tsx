type Tab = 'home' | 'swap' | 'liquidity'

interface HomePageProps {
  setTab: (tab: Tab) => void
}

export default function HomePage({ setTab }: HomePageProps) {
  return (
    <main className="flex flex-col items-center min-h-screen pt-40 pb-20 px-4 relative overflow-hidden">

      {/* Background orbs */}
      <div className="absolute top-[-5%] left-[-10%] w-[55%] h-[55%] bg-primary-dim/10 blur-[140px] rounded-full pointer-events-none" />
      <div className="absolute bottom-[10%] right-[-10%] w-[50%] h-[50%] bg-tertiary/10 blur-[140px] rounded-full pointer-events-none" />
      <div className="absolute top-[40%] left-[40%] w-[30%] h-[30%] bg-secondary/5 blur-[100px] rounded-full pointer-events-none" />

      {/* Hero */}
      <div className="flex flex-col items-center text-center max-w-3xl z-10">
        <div className="inline-flex items-center gap-2 px-4 py-1.5 rounded-full border border-violet-500/30 bg-violet-500/10 text-violet-300 text-xs font-label tracking-widest uppercase mb-8">
          Uniswap v4 · Aave v3 · Base Sepolia
        </div>

        <h1 className="font-headline text-5xl md:text-7xl font-extrabold tracking-tight text-on-surface mb-6 leading-tight">
          Swap smarter.{' '}
          <span className="bg-gradient-to-r from-violet-400 to-pink-500 bg-clip-text text-transparent">
            Earn more.
          </span>
        </h1>

        <p className="font-body text-outline text-lg md:text-xl max-w-2xl leading-relaxed mb-12">
          PoolUp lets you swap USDC ↔ USDT while the pool's liquidity earns{' '}
          <span className="text-slate-200">Uniswap swap fees</span> and{' '}
          <span className="text-slate-200">Aave lending yield</span> simultaneously — with no extra steps.
        </p>

        <div className="flex flex-col sm:flex-row gap-4 mb-20">
          <button
            onClick={() => setTab('swap')}
            className="px-8 py-4 rounded-xl bg-gradient-to-r from-violet-600 to-pink-600 hover:from-violet-500 hover:to-pink-500 text-white font-label text-sm uppercase tracking-widest transition-all duration-200 shadow-lg shadow-violet-900/40"
          >
            Start swapping
          </button>
          <button
            onClick={() => setTab('liquidity')}
            className="px-8 py-4 rounded-xl border border-slate-700 hover:border-violet-500/60 text-slate-300 hover:text-white font-label text-sm uppercase tracking-widest transition-all duration-200 bg-slate-900/40"
          >
            Provide liquidity
          </button>
        </div>
      </div>

      {/* Feature cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6 max-w-4xl w-full z-10">
        <div className="rounded-2xl border border-slate-800 bg-slate-900/50 backdrop-blur-sm p-6">
          <div className="text-2xl mb-3">⚡</div>
          <h3 className="font-headline font-bold text-slate-100 mb-2">Instant swaps</h3>
          <p className="font-body text-sm text-slate-400 leading-relaxed">
            Swap USDC ↔ USDT in two clicks. Quote sourced from the Uniswap Trading API before every transaction.
          </p>
        </div>

        <div className="rounded-2xl border border-violet-500/30 bg-violet-500/5 backdrop-blur-sm p-6">
          <div className="text-2xl mb-3">📈</div>
          <h3 className="font-headline font-bold text-slate-100 mb-2">Double yield for LPs</h3>
          <p className="font-body text-sm text-slate-400 leading-relaxed">
            The pool holds Aave stataTokens. LPs earn swap fees <span className="text-violet-300">+</span> Aave lending yield on every dollar of liquidity — proven up to <span className="text-violet-300">7.47% APY</span> in simulations.
          </p>
        </div>

        <div className="rounded-2xl border border-slate-800 bg-slate-900/50 backdrop-blur-sm p-6">
          <div className="text-2xl mb-3">🔒</div>
          <h3 className="font-headline font-bold text-slate-100 mb-2">Non-rebasing tokens</h3>
          <p className="font-body text-sm text-slate-400 leading-relaxed">
            Aave's StaticATokenLM wrapper keeps the AMM math intact — share price grows instead of balance, making yield accrual invisible to Uniswap.
          </p>
        </div>
      </div>

    </main>
  )
}
