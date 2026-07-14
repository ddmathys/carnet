import type { VercelRequest, VercelResponse } from '@vercel/node'
import { randomUUID } from 'crypto'
import { requireAuth } from '../../lib/verify'
import {
  presignPut,
  presignGet,
  deleteObject,
  signKey,
  verifyKeySignature,
  r2PublicHost,
} from '../../lib/r2'
import {
  memoryIfMember,
  videoKeysOf,
  photoKeysOf,
  audioKeyOf,
} from '../../lib/access'
import { migrateLegacyMedia } from '../../lib/migrate'

// La migration des médias travaille par lots : on lui laisse le temps d'un lot.
export const config = { maxDuration: 60 }

/** URL backend permanente d'un PDF (voir lib/r2.ts) : elle redirige vers une
 *  URL R2 signée fraîche à chaque accès — c'est ce qu'on donne à l'imprimeur. */
function stablePdfUrl(req: VercelRequest, key: string): string {
  const host = req.headers['x-forwarded-host'] ?? req.headers.host ?? ''
  const proto = (req.headers['x-forwarded-proto'] as string) ?? 'https'
  return `${proto}://${host}/api/video/book-pdf?key=${encodeURIComponent(
    key
  )}&sig=${signKey(key)}`
}

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

  if (action === 'book-pdf') {
    // PUBLIC par construction : c'est l'URL qu'on donne à l'imprimeur (Gelato),
    // qui n'a évidemment pas de compte carnet. Elle n'ouvre RIEN d'autre que le
    // PDF dont la clé est signée — sans le HMAC, la clé ne vaut rien, et une
    // clé signée ne permet pas d'en deviner une autre.
    const key = (req.query.key ?? '') as string
    const sig = (req.query.sig ?? '') as string
    if (!key.startsWith('books/') || !verifyKeySignature(key, sig)) {
      return res.status(403).send('Lien invalide')
    }
    try {
      const url = await presignGet(key, 3600)
      res.setHeader('Cache-Control', 'no-store')
      return res.redirect(302, url)
    } catch {
      return res.status(404).send('PDF introuvable')
    }
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

  // ── Audio / mémos vocaux (même infra R2 privée + URLs signées) ───────────
  if (action === 'audio-upload-url') {
    const notebookId = (body.notebookId ?? '') as string
    if (!notebookId) {
      return res.status(400).json({ error: 'notebookId manquant' })
    }
    const contentType = 'audio/mp4'
    const key = `audio/${user.uid}/${notebookId}/${randomUUID()}.m4a`
    try {
      const uploadUrl = await presignPut(key, contentType)
      return res.status(200).json({ uploadUrl, key, contentType })
    } catch {
      return res.status(500).json({ error: 'Signature impossible' })
    }
  }

  if (action === 'audio-play') {
    const memoryId = (body.memoryId ?? '') as string
    const mem = await memoryIfMember(memoryId, user.uid, user.email)
    if (!mem) return res.status(403).json({ error: 'Accès refusé' })
    const key = audioKeyOf(mem)
    const url = key ? await presignGet(key, 3600) : null
    return res.status(200).json({ key, url })
  }

  if (action === 'audio-delete') {
    const key = (body.key ?? '') as string
    if (!key || !key.startsWith(`audio/${user.uid}/`)) {
      return res.status(403).json({ error: 'Clé invalide' })
    }
    try {
      await deleteObject(key)
      return res.status(200).json({ ok: true })
    } catch {
      return res.status(500).json({ error: 'Suppression impossible' })
    }
  }

  // ── PDF des livres (aperçu + commandes imprimées) ────────────────────────
  if (action === 'book-upload-url') {
    // Le PDF part sur R2 comme le reste. On renvoie AUSSI l'URL stable : c'est
    // elle qu'on enregistre dans la commande, et que l'imprimeur suivra.
    const key = `books/${user.uid}/${randomUUID()}.pdf`
    try {
      const uploadUrl = await presignPut(key, 'application/pdf')
      return res.status(200).json({
        uploadUrl,
        key,
        contentType: 'application/pdf',
        url: stablePdfUrl(req, key),
      })
    } catch {
      return res.status(500).json({ error: 'Signature impossible' })
    }
  }

  if (action === 'book-delete') {
    const key = (body.key ?? '') as string
    if (!key || !key.startsWith(`books/${user.uid}/`)) {
      return res.status(403).json({ error: 'Clé invalide' })
    }
    try {
      await deleteObject(key)
      return res.status(200).json({ ok: true })
    } catch {
      return res.status(500).json({ error: 'Suppression impossible' })
    }
  }

  // ── Reprise des médias restés sur Firebase Storage ───────────────────────
  if (action === 'migrate') {
    // Chaque utilisateur migre SES médias, par lots, jusqu'à `remaining == 0`.
    // Le travail vit ici parce que les clés R2 et l'accès Firebase Storage sont
    // au serveur — ni l'app ni un poste de dev ne les ont.
    const limit = Math.min(Math.max(Number(body.limit ?? 5), 1), 20)
    try {
      const report = await migrateLegacyMedia(user.uid, limit, (key) =>
        stablePdfUrl(req, key)
      )
      return res.status(200).json(report)
    } catch (e) {
      return res
        .status(500)
        .json({ error: 'Migration impossible', detail: String(e) })
    }
  }

  return res.status(404).json({ error: 'Action inconnue' })
}
