import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth } from '../../lib/verify'
import { consumeAiQuota } from '../../lib/quota'

const DEEPSEEK_URL = 'https://api.deepseek.com/v1/chat/completions'
const MAX_TOKENS_CAP = 6000
const MAX_PROMPT_CHARS = 60_000

interface ChatMessage {
  role: 'system' | 'user' | 'assistant'
  content: string
}

// Proxy IA authentifié : l'app envoie les messages, le backend détient la clé,
// force le modèle et applique le quota journalier par utilisateur.
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const user = await requireAuth(req, res)
  if (!user) return

  const key = process.env.DEEPSEEK_API_KEY
  if (!key) return res.status(500).json({ error: 'AI not configured' })

  const { messages, maxTokens, temperature } = (req.body ?? {}) as {
    messages?: ChatMessage[]
    maxTokens?: number
    temperature?: number
  }

  if (!Array.isArray(messages) || messages.length === 0 || messages.length > 10) {
    return res.status(400).json({ error: 'Invalid messages' })
  }
  for (const m of messages) {
    if (
      !m ||
      !['system', 'user', 'assistant'].includes(m.role) ||
      typeof m.content !== 'string'
    ) {
      return res.status(400).json({ error: 'Invalid message format' })
    }
  }
  const totalChars = messages.reduce((n, m) => n + m.content.length, 0)
  if (totalChars > MAX_PROMPT_CHARS) {
    return res.status(400).json({ error: 'Prompt too large' })
  }

  const allowed = await consumeAiQuota(user.uid)
  if (!allowed) {
    return res.status(429).json({ error: 'Daily AI quota exceeded' })
  }

  try {
    const upstream = await fetch(DEEPSEEK_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages,
        max_tokens: Math.min(Math.max(Number(maxTokens) || 600, 1), MAX_TOKENS_CAP),
        temperature: Math.min(Math.max(Number(temperature) ?? 0.7, 0), 1.5),
      }),
      signal: AbortSignal.timeout(90_000),
    })

    if (!upstream.ok) {
      console.error('[ai/chat] upstream error', upstream.status, await upstream.text())
      return res.status(502).json({ error: 'AI provider error' })
    }

    const data = (await upstream.json()) as {
      choices: Array<{ message: { content: string } }>
    }
    return res.status(200).json({ content: data.choices[0]?.message?.content ?? '' })
  } catch (err) {
    console.error('[ai/chat]', err)
    return res.status(500).json({ error: 'AI request failed' })
  }
}
