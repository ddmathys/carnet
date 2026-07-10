import type { VercelRequest, VercelResponse } from '@vercel/node'
import { randomUUID } from 'crypto'
import { requireAuth } from '../../lib/verify'
import { presignPut, presignGet, deleteObject, r2PublicHost } from '../../lib/r2'
import { memoryIfMember, videoKeysOf, photoKeysOf } from '../../lib/access'

// Route dynamique regroupant les endpoints vidéo + la config publique en UNE
// seule fonction serverless (le plan Hobby de Vercel plafonne à 12 fonctions).
// Les URLs publiques restent identiques :
//   POST /api/video/upload-url  → URL PUT R2 signée
//   POST /api/video/delete      → suppression d'un objet R2
//   GET  /api/video/config      → { r2PublicHost } (reconstruction d'URL côté app)
export default async function handler(req: VercelRequest, res: VercelResponse) {
  const action = (req.query.action ?? '') as string

  if (action === 'config') {
    // Aucune donnée secrète : l'hôte public R2 permet à l'app de reconstruire
    // les URLs de lecture depuis les CLÉS stockées en base. Réponse cacheable.
    res.setHeader('Cache-Control', 'public, max-age=3600')
    return res.status(200).json({ r2PublicHost })
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const user = await requireAuth(req, res)
  if (!user) return

  const body =
    (typeof req.body === 'string' ? JSON.parse(req.body || '{}') : req.body) ??
    {}

  if (action === 'play') {
    // Lecture sécurisée : on ne délivre des URLs GET signées (durée courte) que
    // si le demandeur est membre du carnet propriétaire du souvenir. Remplace
    // l'ancienne reconstruction d'URL publique (bucket désormais privé).
    const memoryId = (body.memoryId ?? '') as string
    const mem = await memoryIfMember(memoryId, user.uid, user.email)
    if (!mem) return res.status(403).json({ error: 'Accès refusé' })
    const keys = videoKeysOf(mem)
    const urls = await Promise.all(keys.map((k) => presignGet(k, 3600)))
    return res.status(200).json({ keys, urls })
  }

  if (action === 'upload-url') {
    const notebookId = (body.notebookId ?? '') as string
    if (!notebookId) {
      return res.status(400).json({ error: 'notebookId manquant' })
    }
    // La clé inclut l'uid → l'utilisateur ne peut écrire/supprimer que ses objets.
    const contentType = 'video/mp4'
    const key = `videos/${user.uid}/${notebookId}/${randomUUID()}.mp4`
    try {
      const uploadUrl = await presignPut(key, contentType)
      return res.status(200).json({ uploadUrl, key, contentType })
    } catch {
      return res.status(500).json({ error: 'Signature impossible' })
    }
  }

  if (action === 'delete') {
    // Sécurité : on n'autorise la suppression que des objets de l'utilisateur,
    // c.-à-d. dont la clé commence par `videos/{uid}/`.
    const key = (body.key ?? '') as string
    if (!key || !key.startsWith(`videos/${user.uid}/`)) {
      return res.status(403).json({ error: 'Clé invalide' })
    }
    try {
      await deleteObject(key)
      return res.status(200).json({ ok: true })
    } catch {
      return res.status(500).json({ error: 'Suppression impossible' })
    }
  }

  // ── Photos (même infra R2 privée + URLs signées temporaires) ─────────────
  if (action === 'photo-upload-url') {
    const notebookId = (body.notebookId ?? '') as string
    if (!notebookId) {
      return res.status(400).json({ error: 'notebookId manquant' })
    }
    const contentType = 'image/jpeg'
    const key = `photos/${user.uid}/${notebookId}/${randomUUID()}.jpg`
    try {
      const uploadUrl = await presignPut(key, contentType)
      return res.status(200).json({ uploadUrl, key, contentType })
    } catch {
      return res.status(500).json({ error: 'Signature impossible' })
    }
  }

  if (action === 'photo-play') {
    // URLs GET signées (courtes) des photos d'un souvenir, si l'appelant est
    // membre du carnet. Les souvenirs sans `mediaKeys` (anciens) renvoient une
    // liste vide → l'app retombe sur leurs URLs Firebase (double-lecture).
    const memoryId = (body.memoryId ?? '') as string
    const mem = await memoryIfMember(memoryId, user.uid, user.email)
    if (!mem) return res.status(403).json({ error: 'Accès refusé' })
    const keys = photoKeysOf(mem)
    const urls = await Promise.all(keys.map((k) => presignGet(k, 3600)))
    return res.status(200).json({ keys, urls })
  }

  if (action === 'photo-sign') {
    // Signature par lot de clés APPARTENANT à l'appelant (photos/{uid}/…).
    // Sert la génération de livre et les couvertures.
    const raw = Array.isArray(body.keys) ? (body.keys as unknown[]) : []
    const keys = raw.filter(
      (k): k is string =>
        typeof k === 'string' && k.startsWith(`photos/${user.uid}/`)
    )
    const urls = await Promise.all(keys.map((k) => presignGet(k, 3600)))
    return res.status(200).json({ keys, urls })
  }

  if (action === 'photo-delete') {
    const key = (body.key ?? '') as string
    if (!key || !key.startsWith(`photos/${user.uid}/`)) {
      return res.status(403).json({ error: 'Clé invalide' })
    }
    try {
      await deleteObject(key)
      return res.status(200).json({ ok: true })
    } catch {
      return res.status(500).json({ error: 'Suppression impossible' })
    }
  }

  return res.status(404).json({ error: 'Action inconnue' })
}
