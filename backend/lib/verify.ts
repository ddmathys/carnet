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

/** En-têtes de toute page HTML publique servie par le backend.
 *
 *  Ces pages montrent des photos et des vidéos d'enfants à quelqu'un qui n'a
 *  pas de compte (lien de partage, QR d'un poster ou d'un livre, invitation).
 *  Jusqu'au 01.10.26 elles ne portaient AUCUN en-tête de protection : un lien
 *  recopié sur un forum, un blog ou une page publique devenait indexable, et
 *  l'URL signée du média partait dans le `Referer` vers chaque domaine tiers
 *  visité depuis la page.
 *
 *  - `robots`           : jamais d'indexation, jamais de mise en cache par un
 *                         moteur, et pas de suivi des liens de la page ;
 *  - `Referrer-Policy`  : aucune URL de média ne fuit dans un `Referer` ;
 *  - `X-Content-Type-Options` : pas de reniflage de type (un média servi
 *                         comme autre chose ne s'exécute pas) ;
 *  - `X-Frame-Options`  : la page ne s'encadre pas dans un site tiers.
 *
 *  Le `<meta name="robots">` est posé en plus dans chaque gabarit : un
 *  en-tête HTTP ne suit pas la page si elle est enregistrée puis republiée.
 */
export function publicPageHeaders(res: VercelResponse): void {
  res.setHeader('X-Robots-Tag', 'noindex, nofollow, noarchive, noimageindex')
  res.setHeader('Referrer-Policy', 'no-referrer')
  res.setHeader('X-Content-Type-Options', 'nosniff')
  res.setHeader('X-Frame-Options', 'DENY')
}

/** Balise `robots` à poser dans le `<head>` de chaque gabarit public. */
export const NOINDEX_META =
  '<meta name="robots" content="noindex, nofollow, noarchive, noimageindex"/>'

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}
