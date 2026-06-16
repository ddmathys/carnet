# État du projet — point du 16 juin 2026

Note de reprise : où on en est, ce qui reste à faire, et le plan.

## Contexte

Bloom (nom de travail — aussi appelé Folio dans les prompts IA et Carnet dans
les emails : **à unifier un jour**) est un journal de souvenirs multi-carnets
(enfant, voyage, famille, grossesse…) avec narration IA et génération de
livres imprimés. Flutter + Firebase (`bloom-bcb1f`), backend Vercel.

Un audit complet a été fait le 11.06.2026, suivi de la **Phase 0 :
sécurisation** — terminée et déployée ce même jour. Le **16.06.2026** : **Phase 1**
(mémos vocaux), une série d'améliorations UX (compression photo, sauvegarde
optimiste, fixes de spinners), et l'essentiel de **Phase 2 du livre**
(personnalisation, historique, format print-ready, **intégration Gelato API**).

> **Reprise rapide (où on en est le 16.06 au soir)** : tout est codé, analysé
> (0 erreur), commité et poussé. Backend Gelato déployé, env vars posées +
> redéployées. **Console admin débloquée** (fix `permission-denied`). Le
> **nombre de pages Gelato** (pair, ≥28) est géré par bourrage de pages
> blanches. Le **prix suit le nombre de pages**. Il reste **le test réel de
> bout en bout sur device** : générer un **nouveau** livre 21×28 → commander →
> console admin « Envoyer à Gelato (brouillon) » → vérifier le brouillon chez
> Gelato (remplissage du gabarit, acceptation). Pas encore validé en réel (le
> build Flutter ne tourne pas sur cette machine — Developer Mode/symlinks).

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

## ✅ Fait (16.06.2026, suite) — corrections livre + intégration Gelato

### Corrections suite aux tests
- **Spinner plein écran infini à l'ouverture du livre** : `_loadData` n'avait ni
  try/catch ni timeout → si le chargement échoue/pend, `_notebook` reste null →
  spinner muet. Corrigé : timeout 20 s, gestion d'erreur, écran « Réessayer ».
- **Spinner infini sur « Mes livres »** : la requête `generatedBooks` filtrait
  par `notebookId`, mais la règle Firestore autorise sur `userId` → requête de
  liste **refusée** → flux en erreur → spinner sans fin. Corrigé : requête par
  `userId`, filtre `notebookId` + tri **côté client** ; l'UI gère l'erreur.
- **Suppression d'un livre invisible** : le swipe n'était pas découvrable →
  ajout d'un **menu ⋮ (Partager / Supprimer)** explicite sur chaque ligne.
- **Titre/sous-titre « non éditables »** : l'aperçu de couverture lisait le titre
  du carnet et n'affichait pas le sous-titre → édition sans effet visible.
  Corrigé : aperçu **WYSIWYG** piloté en direct par les champs ; le champ titre
  est pré-rempli avec le vrai titre par défaut (« Léa & Nala »).

### Format print-ready Gelato (livre 21×28)
- Gelato n'a **pas d'A4** en livre photo (tailles : 14×14, 20×20, **21×28**).
  Notre PDF était en A4 → **cause racine** du « je dois réajuster chaque image ».
- PDF passé en **21×28 cm + 4 mm de fond perdu** (document 218×288 mm). Images en
  plein fond perdu ; texte/QR/numéro de page rentrés de 4 mm (zone de sécurité).
  Constantes `_a4W/_a4H` dans `book_pdf_service.dart` (nom historique, valent
  désormais 21×28+bleed).

### Intégration Gelato Order API (fabrication automatisée, validation manuelle)
- **Backend** `backend/api/gelato/order.ts` (admin only) : poste la commande
  Firestore vers Gelato v4 (`POST order.gelatoapis.com/v4/orders`, header
  `X-API-KEY`). **`orderType: "draft"` par défaut** → crée un brouillon NON mis
  en production : l'admin l'ajuste/valide dans le dashboard Gelato. Mappe le
  `productUid` selon la couverture (soft/hard), l'URL du PDF, l'adresse (pays →
  ISO), et le **`pageCount`** (envoyé à part — pas dans le UID, donc nb de pages
  variable OK). Stocke `gelatoOrderId/gelatoStatus/gelatoError` sur la commande.
- **Page count** : `generateForNotebook` renvoie désormais `(bytes, pageCount)` ;
  `OrderModel.pageCount` stocké à la commande, relu par le backend.
- **App** : `OrderService.sendToGelato(orderId, orderType)` ; bouton
  **« Envoyer à Gelato (brouillon) »** dans la console admin (affiche l'id du
  brouillon ou l'erreur Gelato + Réessayer).
- **Env vars Vercel (prod)** : `GELATO_API_KEY`, `GELATO_PRODUCT_UID_SOFT`,
  `GELATO_PRODUCT_UID_HARD` → **posées et redéployées**.

### ⬜ En attente / à tester — Gelato (NON validé en réel)
- [ ] Générer un **nouveau** livre (21×28, avec `pageCount`) puis commande test
- [ ] Console admin → « Envoyer à Gelato (brouillon) » → « ✅ Brouillon créé »
- [ ] Dashboard Gelato : le PDF **remplit le gabarit 21×28 sans réajustement**
- [ ] Risque restant si refus : couverture/intérieur en **fichiers séparés**
      (aujourd'hui un seul PDF `type: default`), `shipmentMethodUid` requis →
      à corriger selon le message d'erreur Gelato.
- **Reste pour l'automatisation complète** : **Stripe** (encaisser le client) —
  aujourd'hui paiement « à réception », fabrication déclenchée à la main.

## ✅ Fait (16.06.2026, suite 2) — accès admin, prix, contraintes Gelato, divers

- **Accès admin débloqué (`permission-denied`)** : la règle `isAdmin()`
  exigeait `email_verified`, claim absent/false dans le token → la console admin
  (requête liste de toutes les commandes) était refusée → spinner infini.
  Retiré `email_verified` de `isAdmin()` (Firestore **et** Storage, redéployés) ;
  le claim `email` signé suffit. Console admin résiliente (parse par doc en
  try/catch + affichage de l'erreur au lieu d'un spinner muet).
- **Suppression d'une commande (admin)** : bouton « Supprimer la commande » dans
  la console (`OrderService.deleteOrder` → PDF Storage best-effort + doc
  Firestore). Pour le cas « supprimée chez Gelato → la retirer de l'app ». NB :
  ne supprime que côté app, pas le brouillon Gelato (annulation API possible plus
  tard si voulu).
- **Nombre de pages valide Gelato** : Gelato n'accepte que **pair, 28–200**
  (notre livre faisait 41 → refus). `generateForNotebook(padForPrint: true)`
  ajoute des **pages blanches** jusqu'à la valeur valide ; `pageCount` envoyé =
  PDF padé. Le PDF **digital reste sans bourrage**. Note « 28 pages min »
  affichée sur l'étape format imprimé.
- **Prix aligné sur le nombre de pages** (`book_pricing.dart`) : base
  (souple 24,90 / rigide 34,90, jusqu'à 24 pages) + **0,50 CHF/page** au-delà.
  Affiché partout (cartes, récap avec ligne « Pages », bouton, commande). Le prix
  utilise une **estimation** des pages (≈ couverture + 1 page/photo + pages
  texte) car calculé avant génération. Constantes ajustables.
- **Ligne marketing retirée** : « Satisfait ou remboursé · Livraison offerte ».
- **Bug compteur « 0 souvenirs »** : `notebook.memoriesCount` mis à 0 à la
  création et jamais incrémenté. Le **home compte en direct** via agrégation
  `count()` (total header + chaque carte). Pas 100 % temps réel (recalcul à
  l'ouverture du home), mais toujours juste.
- **Qualité photo → pleine page conditionnelle** : une photo portrait ne passe
  en pleine page que si **largeur ≥ 1400 px** (~170 DPI sur 21 cm) ; sinon
  demi-page (plus petite, pixelisation moins visible). `_imgDims` lit les
  dimensions dans l'en-tête PNG/JPEG. Seuil `_fullPageMinWidthPx` ajustable.
- ⚠️ **DPI** : photos compressées à 2048 px ⇒ pleine page A4/21×28 ≈ 170 DPI
  (> min Gelato 150, < 300 premium). Plafond ajustable dans `photo_service.dart`
  si besoin d'une qualité print HD (uploads plus lourds).

## ✅ Fait (16.06.2026, suite 3) — Partage & quotas

- **Quota photos** : gratuit **300** (affiché) / blocage réel **350**, premium
  **10 000** @ 29 CHF/an. Mémo vocal gratuit pour tous. Blocage à l'ajout de
  photo (`_pickPhotos`) avec popup « Passer premium ». `quota_service.dart`.
- **Suppression de commande (admin)** : bouton dans la console
  (`OrderService.deleteOrder` → PDF + doc).
- **Compteur souvenirs corrigé** (home) : agrégation `count()` en direct.
- **Invitation de carnet par deep link** (`carnet://join?token=…`) :
  - backend `/api/notebook/invite` (crée un token dans `notebookInvites`),
    `/api/notebook/join` (ajoute au `sharedWith` via admin SDK), page web
    `/join` (rebond app + fallback téléchargement). Routes déployées.
  - app : `app_links` (réception), config native Android (intent-filter) + iOS
    (CFBundleURLTypes), `NotebookShareService`, handler dans `main.dart`.
  - **Partage natif** (`share_plus`) d'un message = lien de jonction **+** lien
    APK de téléchargement. Bouton « Partager » + « Copier » dans le sheet.
  - ⚠️ Sans app installée : 2 étapes (installer → rouvrir le lien). Le
    « install → rejoint auto » (deferred deep link) nécessiterait Branch/Adjust
    ou des App Links (https vérifiés) — plus tard.
- **« Partagé avec »** sur le dashboard du carnet : avatars + nombre (+ en
  attente), tap → sheet de gestion. Sinon « Partager ce carnet ».
- **Distribution app** (discuté) : aujourd'hui APK direct
  (`dmathys.dev/download/carnet.apk`, Android sideload). Reco : Firebase App
  Distribution pour la beta, Play Store/App Store pour le public.

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
- **Phase 2 — Le wow du livre** : ✅ portrait pleine page (fait), ✅ titre/
  sous-titre éditables (fait), ✅ historique des livres (fait), ✅ format Gelato
  21×28 (fait), ✅/🟡 **Gelato API en brouillon** (codé + déployé, **test réel à
  faire**). Reste : **Stripe** (paiement en ligne — aujourd'hui « à réception »),
  grilles/rythme de mise en page plus riches, intro personnalisée par
  destinataire (« Chère Mamie… »), aperçu feuilletable avant commande,
  fichiers cover/intérieur séparés pour Gelato si requis.
- **Phase 3 — La boucle famille** (modèle Famileo) : invitations contributeurs
  par deep link ; gazette mensuelle automatique pour le type `famille`.
- **Dette à traiter au fil de l'eau** : unifier le nom (bloom/Folio/carnet),
  découper les écrans géants (`book_generate_screen.dart` 79 Ko,
  `memory_create_screen.dart` 55 Ko…), finir la migration legacy
  children/milestones puis supprimer, sortir `kmp/` du repo, vraie clé de
  signature Android avant le Play Store, tests.

## Infos pratiques

- Backend : Vercel, scope `davidmathys24-2067s-projects`, projet `bloom-backend`,
  alias prod `https://bloom-backend-gray.vercel.app`
- L'URL du backend est dans `lib/core/config/app_config.dart`
  (surchargée possible via `--dart-define=BACKEND_URL=…`)
- Déploiement backend : `cd backend && vercel --prod --yes`
  (⚠️ toute modif d'env var Vercel exige un **redeploy** pour être prise en compte)
- Déploiement règles : `firebase deploy --only firestore:rules,storage --project bloom-bcb1f`
  (auth via `$env:GOOGLE_APPLICATION_CREDENTIALS = <chemin du service account>`)
- Admin app = email `david.mathys24@gmail.com` (vérifié) dans les règles
- **Env vars backend** : `DEEPSEEK_API_KEY`, `RESEND_API_KEY`,
  `FIREBASE_SERVICE_ACCOUNT`, `GELATO_API_KEY`,
  `GELATO_PRODUCT_UID_SOFT`, `GELATO_PRODUCT_UID_HARD`
- **Routes backend** : `/api/ai/chat`, `/api/email/order`, `/api/email/share`,
  `/listen` (→ `/api/listen`, mémo vocal public), `/api/gelato/order` (admin)
- **Collections Firestore** : `notebooks`, `memories`, `orders`,
  `generatedBooks` (historique PDF), `books` (histoires IA legacy), `users`,
  `aiUsage`, + legacy `children`/`milestones`
- **Console admin** : route `/admin/orders` (changer statut, télécharger PDF,
  envoyer à Gelato)
- Format livre PDF : **21×28 cm + 4 mm bleed** (Gelato softcover). Photos
  compressées à 2048 px ⇒ ~170 DPI en pleine page (> min Gelato 150, < 300
  premium — plafond ajustable dans `photo_service.dart` si besoin print HD).
