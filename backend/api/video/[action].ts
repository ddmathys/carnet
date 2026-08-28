import type { VercelRequest, VercelResponse } from '@vercel/node'
import { randomUUID } from 'crypto'
import { requireAuth, escapeHtml } from '../../lib/verify'
import { db } from '../../lib/firebase'
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
import { migrateLegacyMedia, migrateLegacyMediaAll } from '../../lib/migrate'
import { ADMIN_EMAIL } from '../../lib/resend'

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
    const allowedPrefix = key.startsWith('books/') || key.startsWith('posters/')
    if (!allowedPrefix || !verifyKeySignature(key, sig)) {
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

  if (action === 'poster-video-reel') {
    // PUBLIC par construction : c'est l'URL encodée dans le QR code imprimé
    // sur le poster — pas de compte carnet côté visiteur. Le reelId fait
    // office de capacité non-devinable (même principe que listen.ts), lu
    // dans un document `posterReels` séparé des commandes (créé AVANT la
    // commande elle-même, voir `poster-reel-create` ci-dessous : le QR doit
    // déjà être imprimé dans le PDF avant qu'un orderId existe).
    const reelId = (req.query.o ?? '') as string
    res.setHeader('Content-Type', 'text/html; charset=utf-8')
    res.setHeader('Cache-Control', 'public, max-age=300')

    if (!reelId) {
      return res.status(400).send(reelPage('Lien invalide', '<p>Identifiant manquant.</p>'))
    }
    try {
      const reelSnap = await db.collection('posterReels').doc(reelId).get()
      if (!reelSnap.exists) {
        return res.status(404).send(reelPage('Introuvable', '<p>Ce code n’a plus de vidéos associées.</p>'))
      }
      const reel = reelSnap.data() as Record<string, unknown>
      const memoryIds = Array.isArray(reel.memoryIds)
        ? (reel.memoryIds as unknown[]).filter((x): x is string => typeof x === 'string')
        : []
      // `videosOnly` : reel d'un QR de COUVERTURE de livre, qui ne promet que
      // les vidéos (les mémos vocaux, eux, ont déjà leur propre QR sur la page
      // du souvenir dans le livre). Absent = reel de poster : vidéos + audio.
      const videosOnly = reel.videosOnly === true
      // Sélection fine choisie à la commande (poster-reel-create) — si
      // absente (reel de livre, ou ancien reel créé avant cette fonctionnalité),
      // on retombe sur "tout inclure" pour ces souvenirs, comportement d'avant.
      const selectedVideoKeys = Array.isArray(reel.selectedVideoKeys)
        ? new Set((reel.selectedVideoKeys as unknown[]).filter((x): x is string => typeof x === 'string'))
        : null
      const selectedAudioMemoryIds = Array.isArray(reel.selectedAudioMemoryIds)
        ? new Set((reel.selectedAudioMemoryIds as unknown[]).filter((x): x is string => typeof x === 'string'))
        : null

      const medias: { title: string; url: string; kind: 'video' | 'audio' }[] = []
      for (const memoryId of memoryIds) {
        const memSnap = await db.collection('memories').doc(memoryId).get()
        if (!memSnap.exists) continue
        const mem = memSnap.data() as Record<string, unknown>
        const title = typeof mem.title === 'string' ? mem.title : ''
        for (const key of videoKeysOf(mem)) {
          if (selectedVideoKeys && !selectedVideoKeys.has(key)) continue
          const url = await presignGet(key, 3600)
          medias.push({ title, url, kind: 'video' })
        }
        const audioKey = videosOnly ? '' : audioKeyOf(mem)
        if (audioKey && (!selectedAudioMemoryIds || selectedAudioMemoryIds.has(memoryId))) {
          const url = await presignGet(audioKey, 3600)
          medias.push({ title, url, kind: 'audio' })
        }
      }

      if (medias.length === 0) {
        return res.status(404).send(reelPage('Pas encore de souvenir', '<p>Aucune vidéo n’est associée à ce code pour l’instant.</p>'))
      }

      const body = medias
        .map(
          (m) => `
        ${m.title ? `<p class="reelTitle">${escapeHtml(m.title)}</p>` : ''}
        ${
          m.kind === 'video'
            ? `<video controls preload="metadata" src="${escapeHtml(m.url)}"></video>`
            : `<audio controls preload="metadata" src="${escapeHtml(m.url)}" style="width:100%"></audio>`
        }
      `
        )
        .join('')
      return res
        .status(200)
        .send(reelPage(videosOnly ? 'Souvenirs en vidéo' : 'Souvenirs en vidéo et en son', body))
    } catch {
      return res.status(500).send(reelPage('Erreur', '<p>Impossible de charger les vidéos pour l’instant.</p>'))
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
      // 1 h de validité : une vidéo de plusieurs centaines de Mo sur un réseau
      // mobile peut dépasser les 10 min par défaut, et l'URL expirerait en plein
      // envoi (R2 rejetterait alors le PUT).
      const uploadUrl = await presignPut(key, contentType, 3600)
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

  // ── PDF des posters (même infra que les livres, préfixe R2 différent) ────
  if (action === 'poster-upload-url') {
    const key = `posters/${user.uid}/${randomUUID()}.pdf`
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

  if (action === 'poster-delete') {
    const key = (body.key ?? '') as string
    if (!key || !key.startsWith(`posters/${user.uid}/`)) {
      return res.status(403).json({ error: 'Clé invalide' })
    }
    try {
      await deleteObject(key)
      return res.status(200).json({ ok: true })
    } catch {
      return res.status(500).json({ error: 'Suppression impossible' })
    }
  }

  // ── "Reel" vidéo public d'un poster (cible du QR imprimé) ─────────────────
  if (action === 'poster-reel-create') {
    // Créé AVANT la commande (et avant même le paiement) : le QR doit déjà
    // être imprimé dans le PDF au moment où on génère celui-ci, alors que
    // l'orderId n'existe pas encore. Un reel orphelin (poster jamais commandé)
    // est inoffensif — juste un petit doc Firestore qui ne sert jamais.
    const memoryIds = Array.isArray(body.memoryIds)
      ? (body.memoryIds as unknown[]).filter((x): x is string => typeof x === 'string')
      : []
    if (memoryIds.length === 0) {
      return res.status(400).json({ error: 'memoryIds manquant' })
    }
    for (const memoryId of memoryIds) {
      const mem = await memoryIfMember(memoryId, user.uid, user.email)
      if (!mem) return res.status(403).json({ error: `Accès refusé au souvenir ${memoryId}` })
    }
    // Sélection fine cochée côté app (poster_generate_screen.dart) : quelles
    // clés vidéo précises et de quels souvenirs le mémo vocal. Optionnelle —
    // absente/vide, le reader (poster-video-reel) retombe sur "tout inclure"
    // pour ne pas casser un ancien client qui n'enverrait pas ces champs.
    const videoKeys = Array.isArray(body.videoKeys)
      ? (body.videoKeys as unknown[]).filter((x): x is string => typeof x === 'string')
      : undefined
    const audioMemoryIds = Array.isArray(body.audioMemoryIds)
      ? (body.audioMemoryIds as unknown[]).filter((x): x is string => typeof x === 'string')
      : undefined
    const reelId = randomUUID()
    await db.collection('posterReels').doc(reelId).set({
      userId: user.uid,
      memoryIds,
      ...(videoKeys ? { selectedVideoKeys: videoKeys } : {}),
      ...(audioMemoryIds ? { selectedAudioMemoryIds: audioMemoryIds } : {}),
      createdAt: new Date(),
    })
    return res.status(200).json({ reelId })
  }

  // ── "Reel" vidéo public d'un LIVRE (cible du QR de couverture) ───────────
  if (action === 'book-reel-create') {
    // Un seul code pour tout le livre : il rassemble les vidéos de TOUS les
    // souvenirs imprimés. Même page publique que le reel de poster, en mode
    // `videosOnly` (la couverture ne promet que « regarder »).
    //
    // L'identifiant est DÉTERMINISTE (HMAC de l'uid + la sélection) et non
    // tiré au hasard : l'aperçu du livre est régénéré à chaque retouche, et
    // un reelId neuf à chaque fois laisserait derrière lui des dizaines de
    // documents orphelins pour un seul livre. Il reste non devinable — sans
    // le secret HMAC du serveur, connaître les identifiants des souvenirs ne
    // suffit pas à le reconstruire (même capacité que le reel de poster).
    const memoryIds = Array.isArray(body.memoryIds)
      ? (body.memoryIds as unknown[]).filter((x): x is string => typeof x === 'string')
      : []
    if (memoryIds.length === 0) {
      return res.status(400).json({ error: 'memoryIds manquant' })
    }
    // Un livre peut porter des dizaines de souvenirs : on vérifie
    // l'appartenance en parallèle (un `for await` séquentiel dépasserait le
    // budget de 60 s bien avant).
    const members = await Promise.all(
      memoryIds.map((id) => memoryIfMember(id, user.uid, user.email))
    )
    const refusedAt = members.findIndex((m) => !m)
    if (refusedAt >= 0) {
      return res
        .status(403)
        .json({ error: `Accès refusé au souvenir ${memoryIds[refusedAt]}` })
    }
    const reelId = signKey(
      `book-reel:${user.uid}:${[...memoryIds].sort().join(',')}`
    )
    await db.collection('posterReels').doc(reelId).set({
      userId: user.uid,
      memoryIds,
      videosOnly: true,
      source: 'book',
      createdAt: new Date(),
    })
    return res.status(200).json({ reelId })
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

  // ── Balayage admin : migre TOUS les comptes, pas seulement l'appelant ────
  // Ferme l'exposition pour les comptes qui ne rouvrent jamais l'app (donc ne
  // déclenchent jamais la migration self-service ci-dessus).
  if (action === 'migrate-all') {
    if (user.email !== ADMIN_EMAIL) {
      return res.status(403).json({ error: 'Admin uniquement' })
    }
    const limit = Math.min(Math.max(Number(body.limit ?? 20), 1), 50)
    try {
      const report = await migrateLegacyMediaAll(limit, (key) =>
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

// Gabarit HTML de la page publique `poster-video-reel` — même style de carte
// que backend/api/listen.ts, avec une liste de vidéos au lieu d'un seul audio.
function reelPage(titleText: string, body: string): string {
  return `<!DOCTYPE html><html lang="fr"><head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>${escapeHtml(titleText)} · carnet</title>
<style>
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
    background:#f5ece0;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;padding:24px;}
  .card{background:#fff;border-radius:20px;box-shadow:0 4px 24px rgba(0,0,0,.08);
    padding:36px 32px;max-width:480px;width:100%;text-align:center;}
  .brand{color:#3A6648;font-style:italic;font-weight:bold;font-size:20px;margin-bottom:20px;}
  h1{font-size:22px;color:#2d2d2d;margin:0 0 20px;}
  .reelTitle{color:#7a6a5a;font-size:13px;margin:18px 0 6px;text-align:left;}
  video{width:100%;border-radius:12px;display:block;margin-bottom:8px;}
  p{color:#7a6a5a;}
</style></head>
<body><div class="card"><div class="brand">carnet</div><h1>${escapeHtml(titleText)}</h1>${body}</div></body></html>`
}
