import type { VercelRequest, VercelResponse } from '@vercel/node'

// Serverless function: proxies POST /api/uniswap/quote → Uniswap Trading API
// Injects the API key server-side so it is never exposed to the browser.
// In development, the Vite proxy in vite.config.ts handles the same route.
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const apiKey = process.env.UNISWAP_API_KEY
  if (!apiKey) {
    return res.status(500).json({ error: 'UNISWAP_API_KEY not configured' })
  }

  const upstream = await fetch('https://trade-api.gateway.uniswap.org/v1/quote', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
    },
    body: JSON.stringify(req.body),
  })

  const data = await upstream.json()
  return res.status(upstream.status).json(data)
}
