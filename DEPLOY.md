# Déploiement Phase 0 — Sécurisation Bloom

Ordre des opérations. Les étapes 1 et 2 sont **urgentes** et à faire à la main.

## 1. 🔴 Révoquer la clé DeepSeek compromise (URGENT)

La clé `sk-a0368…a045` était embarquée dans l'APK distribué — elle est considérée
comme publique.

1. Va sur https://platform.deepseek.com/api_keys
2. Supprime la clé existante
3. Crée une nouvelle clé → elle ne servira **que** dans Vercel (étape 3), jamais dans l'app

## 2. Clé Resend

1. https://resend.com/api-keys → crée une clé (ou réutilise l'existante si elle
   n'a jamais été dans l'app — l'ancienne config contenait un placeholder, donc
   les emails ne partaient probablement pas)
2. Vérifie que le domaine `dmathys.dev` est bien validé dans Resend
   (sinon les emails depuis `noreply@dmathys.dev` sont refusés)

## 3. Déployer le backend sur Vercel

```powershell
npm i -g vercel
cd backend
vercel login
vercel            # crée le projet (preview)
```

Puis configure les variables d'environnement (Dashboard Vercel → Settings →
Environment Variables, ou `vercel env add`) :

| Variable | Valeur |
|---|---|
| `DEEPSEEK_API_KEY` | la **nouvelle** clé DeepSeek |
| `RESEND_API_KEY` | la clé Resend |
| `FIREBASE_SERVICE_ACCOUNT` | JSON complet du compte de service, sur une ligne |
| `ADMIN_EMAIL` | `david.mathys24@gmail.com` (défaut si absent) |
| `EMAIL_FROM` | `Carnet <noreply@dmathys.dev>` (défaut si absent) |
| `APP_DOWNLOAD_URL` | URL de l'APK (défaut : dmathys.dev/download/carnet.apk) |

Le compte de service : Console Firebase → ⚙️ Paramètres du projet →
Comptes de service → **Générer une nouvelle clé privée** (projet `bloom-bcb1f`).
Colle le contenu du JSON tel quel dans la variable.

Enfin :

```powershell
vercel --prod
```

Note l'URL de production (ex. `https://bloom-backend.vercel.app`).

## 4. Pointer l'app vers le backend

Dans `lib/core/config/app_config.dart`, la valeur par défaut de `backendUrl`
est `https://bloom-backend.vercel.app`. Si ton URL Vercel est différente,
mets-la à jour (ou compile avec `--dart-define=BACKEND_URL=https://…`).

## 5. Déployer les règles Firebase

```powershell
npm i -g firebase-tools
firebase login
firebase use bloom-bcb1f
firebase deploy --only firestore:rules,storage
```

⚠️ Vérifie d'abord dans la console Firebase (Storage → Rules) si les règles
déployées diffèrent du fichier du repo — l'ancien fichier `storage.rules` ne
couvrait pas les chemins réellement utilisés (`photos/`, `covers/`, `pdfs/`,
`orders/{uid}/`), donc soit les uploads échouaient, soit d'autres règles
étaient en place.

## 6. Recompiler et redistribuer l'APK

L'ancien APK contient la clé compromise et appelle DeepSeek en direct — l'IA y
sera morte dès la révocation. Il faut redistribuer :

```powershell
flutter build apk --release
```

et remplacer le fichier sur `dmathys.dev/download/carnet.apk`.

## 7. Checklist de test (avec l'app recompilée)

- [ ] Connexion Google → l'app charge les carnets
- [ ] Créer un souvenir avec analyse IA (texte libre) → la classification fonctionne
- [ ] Ajouter une photo à un souvenir → upload OK (nouvelle règle `photos/{uid}`)
- [ ] Générer un livre (aperçu IA) → le texte se génère
- [ ] Passer une commande test → tu reçois l'email admin + l'email client
- [ ] Partager un carnet avec un autre compte → l'invitation arrive par email
- [ ] Avec un **second compte** : vérifier qu'on ne voit PAS les carnets du premier
- [ ] Console admin (`/admin/orders`) accessible avec ton compte uniquement

## Ce qui a changé (résumé technique)

- **`backend/`** : proxy Vercel — `/api/ai/chat` (DeepSeek, quota journalier
  par utilisateur : 60 appels free / 300 premium), `/api/email/order`,
  `/api/email/share`. Toutes les routes exigent un ID token Firebase.
- **`firestore.rules`** : ownership réel partout. `memories` vérifie l'accès au
  carnet (propriétaire ou `sharedWith`), `orders` lisibles par leur auteur et
  l'admin seulement, `subscriptionTier` non modifiable par l'utilisateur,
  admin identifié par email vérifié.
- **`storage.rules`** : chemins réels (`photos/`, `covers/`, `pdfs/`,
  `orders/`, `users/`) verrouillés par UID, types/tailles de fichiers contrôlés.
- **App Flutter** : plus aucune clé API embarquée. `DeepSeekService` et les
  emails passent par le backend. `claude_service.dart` (code mort) supprimé.
  `migration_service` filtre par utilisateur (compatible nouvelles règles).
