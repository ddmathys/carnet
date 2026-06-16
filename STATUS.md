# État du projet — point du 16 juin 2026

Note de reprise : où on en est, ce qui reste à faire, et le plan.

## Contexte

Bloom (nom de travail — aussi appelé Folio dans les prompts IA et Carnet dans
les emails : **à unifier un jour**) est un journal de souvenirs multi-carnets
(enfant, voyage, famille, grossesse…) avec narration IA et génération de
livres imprimés. Flutter + Firebase (`bloom-bcb1f`), backend Vercel.

Un audit complet a été fait le 11.06.2026, suivi de la **Phase 0 :
sécurisation** — terminée et déployée ce même jour. Le **16.06.2026**, premier
morceau de **Phase 1** livré et déployé : les **mémos vocaux**, puis une série
d'améliorations UX (sauvegarde optimiste, génération du livre) et le début de
**Phase 2** (personnalisation + historique des livres).

## ✅ Fait (16.06.2026) — UX sauvegarde & génération du livre

- **Compression photo avant upload** (`flutter_image_compress`, max 2048 px /
  q85) : ~5 Mo → ~400–700 Ko. Dans `photo_service.dart`.
- **Sauvegarde optimiste façon WhatsApp** : le souvenir (texte) est écrit en
  base et affiché immédiatement ; photos + mémo vocal partent en arrière-plan
  via `MediaUploadQueue` (singleton), qui complète le doc ensuite. La liste
  étant en flux temps réel, les photos apparaissent seules — pas de
  rafraîchissement manuel. Bannière discrète + bouton « Réessayer » sur échec.
- **Fix spinner infini (génération du livre)** : `getIdToken()` n'avait pas de
  timeout dans `backend_client.dart` → corrigé (protège tous les appels IA),
  + garde-fou sur `_generate`.
- **Fix spinner infini (« Ton PDF est prêt »)** : le spinner était lié à la fin
  du partage (`Printing.sharePdf` qui ne revient pas) → découplé, il ne couvre
  plus que la génération des octets (+ timeout 60s) ; le partage est hors
  spinner avec message d'erreur si échec.

## ✅ Fait (16.06.2026) — Phase 2 (début) : livre personnalisé + historique

- **Titre + sous-titre éditables** sur l'écran de génération (champs encadrés,
  étaient sans bordure et invisibles comme tels).
- **Photos portrait en pleine page** dans le PDF (plus de rognage horizontal) ;
  paysages toujours 2/page ; ordre chronologique préservé. Dans
  `book_pdf_service.dart` (pagination orientation-aware).
- **Historique des livres générés** : nouvelle collection Firestore
  `generatedBooks` (≠ `books` qui sert aux histoires IA), `GeneratedBookModel`,
  `BookHistoryService`. Chaque génération (numérique + commande imprimée) crée
  une entrée. Nouvel écran `/notebook/:id/books` : liste, **partage** (tap),
  **suppression** (swipe → doc + fichier Storage ; commande imprimée intacte).
  Le bouton « Livre » du dashboard ouvre l'historique (FAB « Créer un livre ») ;
  stat « Livres générés » branchée sur le vrai compte. Règles `generatedBooks`
  (propriétaire only) **déployées**.

### ⬜ À tester sur téléphone (lot du 16.06, non validé en réel)
- [ ] Sauvegarde d'un souvenir : retour immédiat, bannière d'envoi, photos qui
      apparaissent seules ; cas hors-ligne → « Réessayer »
- [ ] Génération du livre : plus de spinner infini (étape « Créer » et
      « Télécharger »)
- [ ] Titre/sous-titre édités → visibles sur couverture/PDF
- [ ] Photos portrait → pleine page non rognée ; paysages 2/page
- [ ] Clic « Livre » → historique ; partage OK ; suppression OK
- [ ] Commande imprimée → entrée « Imprimé » dans l'historique

## ✅ Fait (Phase 1 — 16.06.2026) — Mémos vocaux

- **Feature complète** : enregistrement / lecture / suppression d'un message
  vocal dans la création de souvenir (toutes catégories), upload Storage
  `audio/{uid}/{notebookId}/`, champs `audioUrl` / `audioDurationMs` sur
  `MemoryModel`, suppression en cascade avec photos/souvenirs.
- **QR « écouter »** imprimé en fin de chaque souvenir dans le livre PDF,
  pointant sur la page publique `/listen?m=<memoryId>` du backend.
- **Backend** : nouvelle route `api/listen.ts` (page publique, le memoryId fait
  capacité — pas d'auth). Déployée sur `bloom-backend-gray.vercel.app`.
- **Rewrite Vercel** `backend/vercel.json` : `/listen → /api/listen`. ⚠️ Sans
  ça, le QR (`$backendUrl/listen`) ferait 404 — le bug a été attrapé et corrigé.
- **Règles Storage** : règle `/audio/{uid}/**` (owner, <25 Mo, `audio/*`)
  ajoutée **et déployée en prod**.
- **Bonus** : l'analyse IA est devenue **non-bloquante** (timeout 5 s → ouvre le
  formulaire, complète les champs vides au retour sans écraser les saisies).
- **Dépendances** : `record`, `audioplayers`, `path_provider`, `url_launcher`
  (ce dernier en amorce Stripe Phase 2). Override local `packages/record_linux`
  (stub) car la version pub casse la compilation — à retirer plus tard.
- **Commits** : `b2e799f` (feature) + `2b572ed` (rewrite), poussés sur GitHub.

### ⬜ À tester sur téléphone (non encore validé en réel)
- [ ] Enregistrer un mémo → sauvegarde OK (upload Storage)
- [ ] Générer un aperçu livre → QR présent en fin de souvenir
- [ ] Scanner le QR → la page `/listen` joue bien l'audio (URL Firebase
      tokenisée — seul le routage 400/404 a été vérifié, pas la lecture réelle)
- [ ] Éditer un souvenir : remplacer / supprimer un mémo existant

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
