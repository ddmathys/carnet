import { initializeApp, getApps, cert, applicationDefault } from 'firebase-admin/app'
import { getAuth } from 'firebase-admin/auth'
import { getFirestore } from 'firebase-admin/firestore'
import { getStorage } from 'firebase-admin/storage'

// FIREBASE_SERVICE_ACCOUNT = JSON complet du compte de service (Console Firebase
// → Paramètres → Comptes de service → Générer une nouvelle clé privée).
// On retient le projectId du compte de service : `cert()` ne le reporte PAS dans
// app.options.projectId, donc on le lit ici (et on le passe explicitement à
// initializeApp). Sert à construire la config Firebase WEB de /watch
// (authDomain = `${projectId}.firebaseapp.com`).
let resolvedProjectId = process.env.FIREBASE_PROJECT_ID ?? ''

function initApp() {
  if (getApps().length > 0) return getApps()[0]
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT
  if (raw) {
    const sa = JSON.parse(raw)
    if (sa.project_id) resolvedProjectId = sa.project_id
    return initializeApp({ credential: cert(sa), projectId: sa.project_id })
  }
  return initializeApp({ credential: applicationDefault() })
}

const app = initApp()

export const auth = getAuth(app)
export const db = getFirestore(app)

export const projectId =
  resolvedProjectId || (app.options.projectId as string | undefined) || ''

/** Bucket Firebase Storage historique. Ne sert plus qu'à VIDER : les médias
 *  partent sur R2 et les fichiers d'origine sont supprimés derrière. */
export const legacyBucket = () =>
  getStorage(app).bucket(`${projectId}.firebasestorage.app`)
