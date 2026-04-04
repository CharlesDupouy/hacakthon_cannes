import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { baseSepolia } from 'wagmi/chains'

export const config = getDefaultConfig({
  appName: 'YieldHook',
  projectId: 'yieldhook-hackathon',
  chains: [baseSepolia],
  ssr: false,
})
