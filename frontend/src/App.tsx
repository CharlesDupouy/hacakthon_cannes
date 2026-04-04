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
    <div className="min-h-screen bg-gradient-to-br from-indigo-50 via-white to-pink-50">
      <header className="flex items-center justify-between px-6 py-4 border-b border-gray-100 bg-white/80 backdrop-blur sticky top-0 z-10">
        <div className="flex items-center gap-3">
          <div className="w-8 h-8 rounded-full bg-gradient-to-br from-indigo-500 to-pink-500" />
          <span className="text-xl font-bold text-gray-900">YieldHook</span>
          <span className="text-xs bg-indigo-100 text-indigo-700 px-2 py-0.5 rounded-full font-medium">Base Sepolia</span>
        </div>
        <ConnectButton />
      </header>

      <main className="max-w-4xl mx-auto px-4 py-10">
        <div className="text-center mb-8">
          <h1 className="text-3xl font-bold text-gray-900 mb-2">Yield-Enhanced Swaps</h1>
          <p className="text-gray-500">Swap USDC ↔ USDT while your liquidity earns Aave yield + Uniswap fees</p>
        </div>

        <div className="flex justify-center mb-8">
          <div className="bg-gray-100 rounded-xl p-1 flex gap-1">
            <button
              onClick={() => setTab('swap')}
              className={`px-6 py-2 rounded-lg font-medium text-sm transition ${
                tab === 'swap'
                  ? 'bg-white text-gray-900 shadow'
                  : 'text-gray-500 hover:text-gray-700'
              }`}
            >
              Swap
            </button>
            <button
              onClick={() => setTab('liquidity')}
              className={`px-6 py-2 rounded-lg font-medium text-sm transition ${
                tab === 'liquidity'
                  ? 'bg-white text-gray-900 shadow'
                  : 'text-gray-500 hover:text-gray-700'
              }`}
            >
              Liquidity
            </button>
          </div>
        </div>

        {tab === 'swap' && (
          <div className="flex justify-center">
            <SwapCard />
          </div>
        )}

        {tab === 'liquidity' && (
          <div className="flex flex-col md:flex-row gap-6 justify-center items-start">
            <LPCard onPositionAdded={() => setRefreshKey((k) => k + 1)} />
            <PositionList refreshKey={refreshKey} />
          </div>
        )}
      </main>

      <footer className="text-center py-8 text-xs text-gray-400 border-t border-gray-100 mt-10">
        <p>YieldHook · Built with Uniswap v4 + Aave StaticATokens · Base Sepolia Testnet</p>
        <p className="mt-1">
          Hook:{' '}
          <a
            href="https://sepolia.basescan.org/address/0xBdF688ee8034C64B8f75ddEBf4468634586FD000"
            target="_blank"
            rel="noreferrer"
            className="underline hover:text-gray-600"
          >
            0xBdF688ee8034C64B8f75ddEBf4468634586FD000
          </a>
        </p>
      </footer>
    </div>
  )
}
