import { useState } from 'react'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import SwapCard from './components/SwapCard'
import LPCard from './components/LPCard'
import PositionList from './components/PositionList'

type Tab = 'swap' | 'liquidity'

export default function App() {
  const [tab, setTab] = useState<Tab>('swap')
  const [refreshKey, setRefreshKey] = useState(0)

  return (
    <div className="min-h-screen bg-background text-on-surface font-body">

      {/* Nav */}
      <nav className="fixed top-0 w-full bg-slate-950/40 backdrop-blur-xl z-50 shadow-[0_0_20px_rgba(189,157,255,0.05)]">
        <div className="flex justify-between items-center px-8 py-4 max-w-7xl mx-auto">
          <div className="flex items-center gap-10">
            <div className="flex flex-col">
              <span className="text-2xl font-bold bg-gradient-to-r from-violet-400 to-pink-500 bg-clip-text text-transparent font-headline">
                PoolUp
              </span>
              <span className="font-label text-[10px] tracking-widest text-slate-400 uppercase hidden md:block">
                Swap USDC ↔ USDT · Earn Aave Yield
              </span>
            </div>
            <div className="hidden md:flex gap-8 items-center">
              <button
                onClick={() => setTab('swap')}
                className={`font-label text-sm uppercase tracking-widest transition-all duration-300 pb-1 ${
                  tab === 'swap'
                    ? 'text-violet-300 border-b-2 border-violet-400'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                Swap
              </button>
              <button
                onClick={() => setTab('liquidity')}
                className={`font-label text-sm uppercase tracking-widest transition-all duration-300 pb-1 ${
                  tab === 'liquidity'
                    ? 'text-violet-300 border-b-2 border-violet-400'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                Liquidity
              </button>
            </div>
          </div>
          <ConnectButton />
        </div>
      </nav>

      {/* Swap page */}
      {tab === 'swap' && (
        <main className="flex flex-col items-center justify-center min-h-screen pt-32 pb-20 px-4 relative overflow-hidden">
          {/* Background orbs */}
          <div className="absolute top-[-10%] left-[-10%] w-[50%] h-[50%] bg-primary-dim/10 blur-[120px] rounded-full pointer-events-none" />
          <div className="absolute bottom-[-10%] right-[-10%] w-[50%] h-[50%] bg-tertiary/10 blur-[120px] rounded-full pointer-events-none" />

          {/* Tab pills */}
          <div className="bg-surface-container-low p-1 rounded-full flex mb-12">
            <button
              onClick={() => setTab('swap')}
              className="px-8 py-2 rounded-full text-sm font-semibold transition-all bg-surface-container-high text-primary shadow-lg font-label"
            >
              Swap
            </button>
            <button
              onClick={() => setTab('liquidity')}
              className="px-8 py-2 rounded-full text-sm font-semibold transition-all text-on-surface-variant hover:text-on-surface font-label"
            >
              Liquidity
            </button>
          </div>

          <SwapCard />

          <p className="mt-8 text-[10px] uppercase tracking-[0.2em] text-outline text-center max-w-md leading-loose">
            Actual swap executes on Base Sepolia via PoolUp contract — LPs earn Aave lending yield + swap fees
          </p>
        </main>
      )}

      {/* Liquidity page */}
      {tab === 'liquidity' && (
        <main className="min-h-screen pt-32 pb-20 px-4 md:px-8 max-w-7xl mx-auto relative">
          {/* Background */}
          <div className="absolute top-0 right-0 -z-10 w-full h-[600px] bg-gradient-to-b from-primary/5 via-transparent to-transparent opacity-30 pointer-events-none" />
          <div className="absolute top-[20%] left-[-10%] -z-10 w-96 h-96 bg-tertiary/10 rounded-full blur-[120px] pointer-events-none" />

          <header className="mb-12">
            <h1 className="font-headline font-extrabold text-5xl md:text-6xl tracking-tight text-on-surface mb-4">
              Pools &{' '}
              <span className="bg-gradient-to-r from-primary to-secondary bg-clip-text text-transparent">
                Liquidity
              </span>
            </h1>
            <p className="font-body text-outline max-w-2xl text-lg">
              Provide assets to earn trading fees and Aave yield. Manage your positions or add new liquidity.
            </p>
          </header>

          <div className="grid grid-cols-1 lg:grid-cols-12 gap-8 items-start">
            <section className="lg:col-span-7">
              <LPCard onPositionAdded={() => setRefreshKey((k) => k + 1)} />
            </section>
            <aside className="lg:col-span-5">
              <PositionList refreshKey={refreshKey} />
            </aside>
          </div>
        </main>
      )}

      {/* Footer */}
      <footer className="bg-slate-950 w-full py-12 px-8 border-t border-slate-900">
        <div className="flex flex-col md:flex-row justify-between items-center gap-4 opacity-80 max-w-7xl mx-auto">
          <div className="flex flex-col items-center md:items-start gap-1">
            <span className="text-lg font-bold text-slate-200 font-headline">PoolUp</span>
            <p className="font-label text-xs tracking-tighter text-slate-500">© 2024 PoolUp. Powered by Uniswap v4 &amp; Aave.</p>
          </div>
          <div className="flex gap-8 font-label text-xs tracking-tighter">
            <a href="https://sepolia.basescan.org/address/0xBdF688ee8034C64B8f75ddEBf4468634586FD000" target="_blank" rel="noreferrer" className="text-slate-500 hover:text-violet-400 transition-colors">Contract</a>
            <a href="https://github.com" target="_blank" rel="noreferrer" className="text-slate-500 hover:text-violet-400 transition-colors">GitHub</a>
            <a href="https://developers.uniswap.org" target="_blank" rel="noreferrer" className="text-slate-500 hover:text-violet-400 transition-colors">Docs</a>
          </div>
        </div>
      </footer>
    </div>
  )
}
