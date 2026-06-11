# État du projet — point du 11 juin 2026

Note de reprise : où on en est, ce qui reste à faire, et le plan.

## Contexte

Bloom (nom de travail — aussi appelé Folio dans les prompts IA et Carnet dans
les emails : **à unifier un jour**) est un journal de souvenirs multi-carnets
(enfant, voyage, famille, grossesse…) avec narration IA et génération de
livres imprimés. Flutter + Firebase (`bloom-bcb1f`), backend Vercel.

Un audit complet a été fait le 11.06.2026, suivi de la **Phase 0 :
sécurisation** — terminée et déployée ce même jour.

## ✅ Fait (Phase 0 — 11.06.2026)

- **Audit** : failles critiques identifiées (clé API DeepSeek embarquée dans
  l'APK, règles Firestore/Storage ouvertes à tout utilisateur authentifié,
  premium auto-attribuable, emails en échec silencieux, 7 semaines de travail
  non commitées).
- **Backend Vercel** déployé : `https://bloom-backend-gray.vercel.app`
  (projet `bloom-backend`, code dans `backend/`)
  - `/api/ai/chat` : proxy DeepSeek, token Firebase obligatoire, quota
    journalier serveur (60 free / 300 premium, collection `aiUsage`)
  - `/api/email/order` : emails de commande (admin + client) via Resend
  - `/api/email/share` : invitation carnet partagé
  - Env vars configurées : `DEEPSEEK_API_KEY` (nouvelle clé — l'ancienne
    `sk-a0368…` est **révoquée**), `RESEND_API_KEY`, `FIREBASE_SERVICE_ACCOUNT`
- **Règles Firestore + Storage** réécrites avec ownership réel et
  **déployées en production** (`firebase deploy --only firestore:rules,storage`)
- **App Flutter** : plus aucune clé API embarquée ; IA et emails passent par
  le backend ; `claude_service.dart` (mort) supprimé ; migration filtrée par
  utilisateur ; fix ProGuard ML Kit pour le build release
- **Git** : repo poussé sur https://github.com/ddmathys/carnet (privé)
- **APK release compilé** : `build/app/outputs/flutter-apk/app-release.apk`
  (94 Mo, pointe sur le backend de prod)

## ⬜ À faire à la reprise

1. **Tester l'APK sur téléphone** (checklist complète dans `DEPLOY.md`) :
   - [ ] Connexion Google → carnets visibles
   - [ ] Souvenir en texte libre → classification IA OK (= backend OK)
   - [ ] Ajout photo → upload OK (= règles Storage OK)
   - [ ] Aperçu livre IA OK
   - [ ] Commande test → 2 emails reçus (admin + client)
   - [ ] **Second compte Google** : ne voit PAS les carnets du premier
2. Si tout est vert : remplacer l'APK sur `dmathys.dev/download/carnet.apk`
   et prévenir les utilisateurs (l'ancien APK n'a plus d'IA, clé révoquée)
3. Déplacer `bloom-bcb1f-firebase-adminsdk-*.json` hors du repo
   (gitignoré mais c'est la clé maîtresse de la base)

## 📋 Plan des phases suivantes (issu de l'audit)

- **Phase 1 — Le wow de la capture** : IA vision (Claude via backend, DeepSeek
  n'a pas de vision) → photo + 3 mots = 3 propositions de narration (poétique,
  tendre, factuelle) ; mode interview vocal (speech_to_text déjà présent) ;
  compression des photos avant upload (`flutter_image_compress`) + date EXIF
  auto ; notification « il y a un an ».
- **Phase 2 — Le wow du livre** : mises en page intelligentes (pleine page,
  grilles, rythme — aujourd'hui 2 photos/page fixe) ; intro personnalisée par
  destinataire (« Chère Mamie… ») ; aperçu feuilletable avant commande ;
  Stripe + Gelato/Lulu print-on-demand (aujourd'hui : fabrication manuelle,
  paiement à réception).
- **Phase 3 — La boucle famille** (modèle Famileo) : invitations contributeurs
  par deep link ; gazette mensuelle automatique pour le type `famille`.
- **Dette à traiter au fil de l'eau** : unifier le nom (bloom/Folio/carnet),
  découper les écrans géants (`book_generate_screen.dart` 79 Ko,
  `memory_create_screen.dart` 55 Ko…), finir la migration legacy
  children/milestones puis supprimer, sortir `kmp/` du repo, vraie clé de
  signature Android avant le Play Store, tests.

## Infos pratiques

- Backend : Vercel, scope `davidmathys24-2067s-projects`, projet `bloom-backend`
- L'URL du backend est dans `lib/core/config/app_config.dart`
  (surchargée possible via `--dart-define=BACKEND_URL=…`)
- Déploiement backend : `cd backend && vercel --prod`
- Déploiement règles : `firebase deploy --only firestore:rules,storage --project bloom-bcb1f`
  (auth via `$env:GOOGLE_APPLICATION_CREDENTIALS = <chemin du service account>`)
- Admin app = email `david.mathys24@gmail.com` (vérifié) dans les règles
