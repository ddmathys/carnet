import { initializeApp, getApps, cert, applicationDefault } from 'firebase-admin/app'
import { getAuth } from 'firebase-admin/auth'
import { getFirestore } from 'firebase-admin/firestore'

// FIREBASE_SERVICE_ACCOUNT = JSON complet du compte de service (Console Firebase
// → Paramètres → Comptes de service → Générer une nouvelle clé privée).
function initApp() {
  if (getApps().length > 0) return getApps()[0]
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT
  if (raw) {
    return initializeApp({ credential: cert(JSON.parse(raw)) })
  }
  return initializeApp({ credential: applicationDefault() })
}

const app = initApp()

export const auth = getAuth(app)
export const db = getFirestore(app)
