import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { baseSepolia } from 'wagmi/chains'

export const config = getDefaultConfig({
  appName: 'PoolUp',
  projectId: 'poolup-hackathon',
  chains: [baseSepolia],
  ssr: false,
})
