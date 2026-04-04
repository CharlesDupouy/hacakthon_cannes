import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')

  return {
    plugins: [react()],
    server: {
      proxy: {
        // Forward /api/uniswap/* → https://trade-api.gateway.uniswap.org/v1/*
        // and inject the API key server-side (avoids CORS + exposes key in browser)
        '/api/uniswap': {
          target: 'https://trade-api.gateway.uniswap.org/v1',
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/api\/uniswap/, ''),
          configure: (proxy) => {
            proxy.on('proxyReq', (proxyReq) => {
              proxyReq.setHeader('x-api-key', env.VITE_UNISWAP_API_KEY ?? '')
            })
          },
        },
      },
    },
  }
})
