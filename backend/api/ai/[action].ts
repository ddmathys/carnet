import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth } from '../../lib/verify'
import { db, projectId } from '../../lib/firebase'
import { memoryIfMember, photoKeysOf } from '../../lib/access'
import { presignGet } from '../../lib/r2'
import { consumeAiQuota } from '../../lib/quota'

// Analyses IA d'images (Gemini). Une seule fonction pour toutes les actions —
// le plan Vercel Hobby plafonne à 12 fonctions par déploiement (c'est pour
// libérer ce slot que les deux envois d'e-mails ont fusionné dans
// api/email/[action].ts).
//
//   POST /api/ai/photo-focus  { memoryId, ids: string[] }
//     -> point de recadrage (sujet principal) de chaque photo, normalisé 0..1.
//
// La clé Gemini ne quitte jamais le serveur, et l'appelant ne choisit JAMAIS
// l'image analysée par une URL : il donne des identifiants que le backend
// recoupe avec le souvenir dont il a vérifié qu'il est membre.
export const config = { maxDuration: 60 }

// Au-delà, le téléchargement des photos + l'appel Gemini sortent du
// maxDuration. L'app découpe sa liste en lots de cette taille (PhotoFocusService).
const MAX_IDS_PER_CALL = 8
const MAX_IMAGE_BYTES = 6 * 1024 * 1024

// Alias flottant de Google vers le Flash courant — ne jamais figer une
// version : `gemini-2.5-flash` a déjà renvoyé un 404 « no longer available to
// new users » en cours de développement sur un autre projet.
const GEMINI_MODEL = 'gemini-flash-latest'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }
  const user = await requireAuth(req, res)
  if (!user) return

  const action = String(req.query.action ?? '')
  if (action === 'photo-focus') return photoFocus(req, res, user.uid)

  return res.status(404).json({ error: 'Unknown action' })
}

/** Point de recadrage d'une photo, en coordonnées normalisées (0..1). */
interface Focus {
  id: string
  x: number
  y: number
}

async function photoFocus(req: VercelRequest, res: VercelResponse, uid: string) {
  const apiKey = process.env.GEMINI_API_KEY
  if (!apiKey) {
    return res.status(500).json({ error: 'GEMINI_API_KEY absente côté serveur' })
  }

  const body = (req.body ?? {}) as Record<string, unknown>
  const memoryId = typeof body.memoryId === 'string' ? body.memoryId : ''
  const asked = Array.isArray(body.ids)
    ? (body.ids as unknown[]).filter(
        (v): v is string => typeof v === 'string' && v.length > 0
      )
    : []
  if (!memoryId || asked.length === 0) {
    return res.status(400).json({ error: 'memoryId et ids requis' })
  }
  if (asked.length > MAX_IDS_PER_CALL) {
    return res
      .status(400)
      .json({ error: `Au plus ${MAX_IDS_PER_CALL} photos par appel` })
  }

  const mem = await memoryIfMember(memoryId, uid)
  if (!mem) return res.status(403).json({ error: 'Souvenir inaccessible' })

  // Seules les photos QUE PORTE ce souvenir sont analysables : l'identifiant
  // reçu doit figurer dans ses clés R2 ou dans ses URLs Firebase historiques.
  // Sans ce recoupement, n'importe quelle clé du bucket serait lisible par
  // n'importe quel membre de n'importe quel souvenir.
  const ownKeys = new Set(photoKeysOf(mem))
  const ownUrls = new Set<string>([
    ...(Array.isArray(mem.mediaUrls)
      ? (mem.mediaUrls as unknown[]).filter(
          (v): v is string => typeof v === 'string'
        )
      : []),
    ...(typeof mem.photoUrl === 'string' && mem.photoUrl
      ? [mem.photoUrl as string]
      : []),
  ])
  const ids = asked.filter((id) => ownKeys.has(id) || ownUrls.has(id))
  if (ids.length === 0) {
    return res
      .status(400)
      .json({ error: 'Aucune de ces photos n appartient a ce souvenir' })
  }

  // Déjà analysé = déjà payé : une régénération de livre ne doit rien recoûter.
  const known = parseFocusList(mem.mediaFocus)
  const todo = ids.filter((id) => !known.some((f) => f.id === id))
  if (todo.length === 0) {
    return res
      .status(200)
      .json({ focus: known.filter((f) => ids.includes(f.id)), cached: true })
  }

  if (!(await consumeAiQuota(uid))) {
    return res
      .status(429)
      .json({ error: 'Quota IA du jour atteint, réessaie demain' })
  }

  const images: Array<{ id: string; data: string; mimeType: string }> = []
  for (const id of todo) {
    const img = await loadImage(id)
    if (img) images.push({ id, ...img })
  }
  if (images.length === 0) {
    return res.status(502).json({ error: 'Aucune photo lisible' })
  }

  let fresh: Focus[]
  try {
    fresh = await askGemini(apiKey, images)
  } catch (e) {
    console.error('[ai/photo-focus]', e)
    return res.status(502).json({ error: 'Analyse indisponible' })
  }

  if (fresh.length > 0) await mergeFocus(memoryId, fresh)

  const all = [...known, ...fresh]
  return res.status(200).json({ focus: all.filter((f) => ids.includes(f.id)) })
}

/** Télécharge une photo depuis R2 (clé) ou depuis le Storage historique (URL).
 *  Retourne null plutôt que d'échouer : une photo illisible garde simplement
 *  le cadrage par défaut. */
async function loadImage(
  id: string
): Promise<{ data: string; mimeType: string } | null> {
  try {
    let url: string
    if (/^https?:\/\//.test(id)) {
      // URL Firebase historique : on n'accepte que notre propre bucket.
      const u = new URL(id)
      const okHost = u.hostname === 'firebasestorage.googleapis.com'
      const okPath = u.pathname.startsWith(
        `/v0/b/${projectId}.firebasestorage.app/o/`
      )
      if (!okHost || !okPath) return null
      url = id
    } else {
      url = await presignGet(id, 600)
    }

    const resp = await fetch(url, { signal: AbortSignal.timeout(10000) })
    if (!resp.ok) return null
    const mimeType = resp.headers.get('content-type') ?? 'image/jpeg'
    if (!mimeType.startsWith('image/')) return null
    const buf = await resp.arrayBuffer()
    if (buf.byteLength > MAX_IMAGE_BYTES) return null
    return { data: Buffer.from(buf).toString('base64'), mimeType }
  } catch {
    return null
  }
}

async function askGemini(
  apiKey: string,
  images: Array<{ id: string; data: string; mimeType: string }>
): Promise<Focus[]> {
  // Les images sont numérotées dans le texte : la réponse renvoie l'indice, pas
  // l'identifiant — aucune clé de stockage ne part chez Google.
  const parts: Array<Record<string, unknown>> = []
  images.forEach((img, i) => {
    parts.push({ text: `Image ${i} :` })
    parts.push({ inlineData: { mimeType: img.mimeType, data: img.data } })
  })
  parts.push({
    text: [
      "Pour CHAQUE image ci-dessus, donne le point qui doit rester visible si la photo est recadrée pour remplir un cadre d'un autre format : le centre du sujet principal (le visage, ou le groupe de visages s'il y en a plusieurs ; sinon le sujet le plus net et le plus proche).",
      'Coordonnées normalisées : x de 0 (bord gauche) à 1 (bord droit), y de 0 (bord haut) à 1 (bord bas).',
      'Réponds UNIQUEMENT par un objet JSON valide, sans texte autour :',
      '{"f":[{"i":<numéro de l\'image>,"x":<0..1>,"y":<0..1>}]}',
      "Une entrée par image, dans l'ordre. Si aucun sujet ne se distingue, renvoie x=0.5 et y=0.5.",
    ].join('\n'),
  })

  const resp = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${apiKey}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ parts }],
        generationConfig: {
          responseMimeType: 'application/json',
          temperature: 0,
        },
      }),
      signal: AbortSignal.timeout(45000),
    }
  )
  if (!resp.ok) {
    throw new Error(
      `Gemini ${resp.status}: ${(await resp.text()).slice(0, 300)}`
    )
  }

  const data = (await resp.json()) as Record<string, any>
  const text: string | undefined =
    data.candidates?.[0]?.content?.parts?.[0]?.text
  if (!text) throw new Error('Réponse Gemini vide')

  const parsed = JSON.parse(text) as Record<string, unknown>
  const rows = Array.isArray(parsed.f)
    ? (parsed.f as Array<Record<string, unknown>>)
    : []

  const out: Focus[] = []
  for (const r of rows) {
    const i = Number(r?.i)
    if (!Number.isInteger(i) || i < 0 || i >= images.length) continue
    const x = clamp01(Number(r?.x))
    const y = clamp01(Number(r?.y))
    if (x === null || y === null) continue
    out.push({ id: images[i].id, x, y })
  }
  // Une image sans réponse exploitable n'est PAS inventée : elle garde le
  // cadrage par défaut, et sera retentée au prochain livre.
  return out
}

function clamp01(v: number): number | null {
  if (!Number.isFinite(v)) return null
  return v < 0 ? 0 : v > 1 ? 1 : v
}

/** `mediaFocus` est une LISTE, pas une map : les identifiants de photos (clés
 *  R2, URLs) contiennent des '/' et des '.', mal venus comme noms de champs —
 *  même raison que `photoTexts` dans bookDrafts. */
function parseFocusList(raw: unknown): Focus[] {
  if (!Array.isArray(raw)) return []
  const out: Focus[] = []
  for (const e of raw as Array<Record<string, unknown>>) {
    const id = typeof e?.id === 'string' ? e.id : ''
    const x = clamp01(Number(e?.x))
    const y = clamp01(Number(e?.y))
    if (id && x !== null && y !== null) out.push({ id, x, y })
  }
  return out
}

/** Fusionne les nouveaux points dans `mediaFocus` sans écraser ce qu'un autre
 *  appel concurrent (deux livres générés en parallèle) vient d'y écrire. */
async function mergeFocus(memoryId: string, fresh: Focus[]): Promise<void> {
  const ref = db.collection('memories').doc(memoryId)
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref)
    if (!snap.exists) return
    const current = parseFocusList(snap.data()?.mediaFocus)
    const merged = [...current]
    for (const f of fresh) {
      const at = merged.findIndex((m) => m.id === f.id)
      if (at >= 0) {
        merged[at] = f
      } else {
        merged.push(f)
      }
    }
    tx.update(ref, { mediaFocus: merged })
  })
}
