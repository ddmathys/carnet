import type { VercelRequest, VercelResponse } from '@vercel/node'
import { auth } from './firebase'

export interface AuthedUser {
  uid: string
  email: string | null
}

// Vérifie le header "Authorization: Bearer <Firebase ID token>".
// Retourne l'utilisateur, ou null après avoir écrit la réponse 401.
export async function requireAuth(
  req: VercelRequest,
  res: VercelResponse
): Promise<AuthedUser | null> {
  const header = req.headers.authorization ?? ''
  const token = header.startsWith('Bearer ') ? header.slice(7) : null
  if (!token) {
    res.status(401).json({ error: 'Missing Authorization header' })
    return null
  }
  try {
    const decoded = await auth.verifyIdToken(token)
    return { uid: decoded.uid, email: decoded.email ?? null }
  } catch {
    res.status(401).json({ error: 'Invalid or expired token' })
    return null
  }
}

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}
