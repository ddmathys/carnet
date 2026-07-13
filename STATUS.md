# État du projet — point du 16 juin 2026

Note de reprise : où on en est, ce qui reste à faire, et le plan.

---

## ⚡ REPRISE — 13.07.2026 (soir) : les carnets sont devenus des tags

**Tout est en prod** (`master`, dernier commit `fefa4da`) : APK compilé par
GitHub Actions ✅, règles Firestore déployées ✅, backend Vercel déployé ✅.
APK de test : `C:\Users\karin\Downloads\carnet-apk\app-release.apk` (97 Mo,
signé avec le keystore fixe → s'installe par-dessus l'ancien).

### Ce qui a changé

Le **souvenir** devient l'objet central ; **les carnets disparaissent de l'UI**
et sont remplacés par des **tags**. La collection `notebooks` reste en coulisse
comme « espace » unique par utilisateur (`SpaceService`) : elle porte encore la
sécurité héritée, les quotas et les clés de stockage R2. **Ne pas la supprimer.**

- **Tags** (collection `tags`) : `label`, `kind` (`libre` / `annee` / `lieu` /
  `enfant`), `color`, `birthdate` pour un tag enfant, `sharedWith`,
  `invitedEmails`. À la création d'un souvenir, **l'année et le lieu sont
  tagués d'office** (retirables).
- **Souvenirs** : nouveaux champs `userId`, `tagIds`, `tagLabels`, `sharedWith`.
  `sharedWith` = réunion des collaborateurs des tags **+ le propriétaire de
  chaque tag**, moins le propriétaire du souvenir. C'est ce champ dénormalisé
  que lisent les règles Firestore et le contrôle d'accès aux médias — il doit
  être recopié à chaque changement de tag ou de partage
  (`TagService._propagateSharing`).
- **Partage par tag, par lien uniquement** (`api/tag/[action].ts` → `invite` /
  `join`, Admin SDK) : l'invité voit et enrichit les souvenirs du tag, présents
  et futurs. Pas d'invitation par email (l'invité n'a pas le droit d'écrire chez
  le propriétaire tant qu'il n'a pas rejoint → impasse).
- **Migration one-shot** (`TagMigrationService`, jouée au splash) : 1 carnet →
  1 tag de même nom (partage repris), chaque souvenir reçoit le tag de son
  carnet + celui de son année, `userId`/`sharedWith` remplis, `notebookId`
  repointé sur l'espace. Flag `users/{uid}.tagsMigratedAt`. **Le lieu n'est PAS
  tagué rétroactivement** (le texte libre aurait fabriqué des doublons).
- **Écrans** : dashboard (import direct → `/memory/new?import=1`, filtre par
  tags, **6 derniers souvenirs**, « Mes livres », « Créer un livre » **en bas**) ;
  création (médias → titre → description facultative → date → lieu → tags →
  **mémo vocal en dernier**) ; `/memories` ; `/book/select` (filtre par tags +
  coche souvenir par souvenir) ; `/books` ; `/growth/:tagId` (tag enfant).
- **Sélecteur de tags unique** (`tag_picker_sheet.dart`), utilisé partout :
  sections **Date / Lieu / Événement**, multi-sélection, bouton Valider,
  création à la volée. Filtre = **OU dans une catégorie, ET entre catégories**.
- **Supprimés** : tous les écrans carnet, `book_shelf`, `multi_notebook_select`,
  `notebook_share_service`, écrans `children`/`milestones` hérités.

### ⚠️ À savoir

- **Un collaborateur resté sur l'ANCIEN APK est bloqué** : il ne peut plus créer
  (la règle exige `userId`) et ne voit plus rien (son app cherche encore par
  `notebookId`, or les souvenirs ont été repointés sur l'espace). C'est ce qui
  est arrivé à la femme de David → **elle doit installer le nouvel APK**.
- **L'aperçu du livre était cassé depuis la refonte terracotta** (10.07), pas par
  les tags : le PDF charge ses polices **par chemin** (`rootBundle`), or les
  familles avaient été repointées vers Fraunces/Outfit → les TTF historiques
  n'étaient plus embarqués dans l'APK (« Unable to load asset
  PlayfairDisplay-Regular.ttf »). Corrigé en ajoutant `assets/fonts/` aux assets
  du `pubspec.yaml`. **À revérifier sur device.**
- Pas de SDK Flutter sur ce PC → **le build GitHub Actions est le compilateur**
  (`gh run watch`, erreurs Dart via `gh run view <id> --log-failed`).

### 🔜 Chantier suivant : tout migrer de Firebase Storage vers R2

David veut **plus aucun média sur Firebase**. Aujourd'hui : les médias créés
**depuis le 11.07 sont sur R2** ; les plus anciens sont restés sur Firebase
Storage (URLs à jeton permanent, lues en double-lecture). Les uploads neufs vont
tous sur R2 (`MediaUploadQueue`).

Script déjà écrit : **`backend/scripts/firebase-to-r2.ts`** (`--scan` / `--copy`
/ `--purge` ; la purge vérifie l'existence de la copie R2 avant toute
suppression, et `--copy` note les chemins d'origine dans `legacyStoragePaths`).

**Blocage à lever** : `vercel env pull` renvoie des **valeurs vides** (variables
sensibles chiffrées) → impossible de lancer le script en local sans les secrets.
Deux options, à trancher avec David :

- **A (recommandé)** : exposer la migration en action d'administration sur le
  backend Vercel (là où les clés vivent déjà), protégée par un jeton posé en
  variable d'env, et la piloter par lots depuis le poste. Aucun secret ne
  transite. ⚠️ Plan Hobby = **12 fonctions max** → greffer l'action sur une
  route dynamique existante, ne PAS créer un nouveau fichier dans `api/`.
- **B** : récupérer en local la clé de service Firebase (console → Comptes de
  service) et les identifiants R2 (Cloudflare), puis lancer le script tel quel.

Les **PDF des livres** (`pdfs/`, `orders/`) restent sur Firebase Storage : Gelato
a besoin d'une URL stable. À traiter séparément si on veut vraiment tout fermer.

---

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
> Gelato (remplissage du gabarit, acceptation).
>
> **MÀJ 18.06.2026** : le **build Flutter tourne bien sur cette machine** (hot
> restart OK sur device SM A556B) — l'ancienne note « build cassé / symlinks »
> était fausse. Les tests sur téléphone sont donc possibles.
>
> ✅ **Lien de téléchargement réparé (18.06)** : `dmathys.dev` était en 404
> Vercel (`DEPLOYMENT_NOT_FOUND`, domaine sans déploiement). Désormais : projet
> Vercel **`landing`** (dossier `landing/`) servant une page de téléchargement
> brandée sur `dmathys.dev`, avec redirect `/download/carnet.apk` → APK hébergé
> sur **Firebase Storage** `public/carnet.apk` (lecture publique, règle
> déployée). APK **recompilé à jour** et uploadé (94,9 Mo). Chaîne testée OK
> (dmathys.dev → bouton → redirect → APK, HTTP 206). Pour mettre à jour l'app :
> `flutter build apk --release` puis
> `gsutil cp build/app/outputs/flutter-apk/app-release.apk gs://bloom-bcb1f.firebasestorage.app/public/carnet.apk`.
>
> **MÀJ 21.06.2026** : **vidéos multiples par souvenir + lecture inline** (voir
> section dédiée plus bas). Au passage, gros fix d'infra : le **backend Vercel
> était hors ligne** (déploiement échoué — plan Hobby plafonné à **12 fonctions
> serverless**, on était à 13-14). Endpoints fusionnés en route dynamique
> `api/video/[action].ts` (upload-url + delete + config) → 12 pile, redéployé,
> prod de nouveau en ligne. Et **R2 n'était configuré qu'à moitié** : il manquait
> `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_PUBLIC_HOST` (d'où l'upload vidéo qui n'avait
> jamais pu marcher). Les 3 ajoutées + bucket R2 passé en accès public
> (`pub-e6f508…r2.dev`). **Reste à faire** : rebuild l'app et tester l'upload de
> 2-3 vidéos de bout en bout sur device.
>
> **MÀJ 23.06.2026** : **sécurisation des vidéos par appartenance au carnet**
> (bucket R2 privé + URLs signées), gros lot UX/produit, **refonte de la courbe de
> croissance** et **nouveau type de carnet « Moi »**. Détails dans la section dédiée
> ci-dessous. Tout compile (`flutter analyze` = 0 erreur), backend redéployé.
> **Reste** : rebuild + redistribuer l'APK (indispensable pour que les
> collaborateurs revoient les vidéos, le bucket étant désormais privé) + tests device.

## ✅ Fait (23.06.2026) — Sécurité médias, UX, courbe, étude de marché

### Vidéos : accès sécurisé (bucket R2 privé)
- **Bug upload corrigé** : `R2_BUCKET` valait `bloom-videos` au lieu de
  `carnet-videos` → R2 renvoyait **403 AccessDenied**. Corrigé sur Vercel. Ajout
  aussi de `requestChecksumCalculation:'WHEN_REQUIRED'` sur le client S3 (compat R2
  vs checksum CRC32 par défaut du SDK ≥ 3.729).
- **Lecture sécurisée** : bucket R2 **passé en privé** (Public Dev URL désactivée).
  Nouvel endpoint `POST /api/video/play` (auth + vérif membre via
  `backend/lib/access.ts` `memoryIfMember` = propriétaire / `sharedWith` /
  `invitedEmails`) → **URLs GET signées 1 h**. L'app
  (`VideoService.playbackUrls(memoryId)`) et la page `/watch` passent par là ;
  `resolveVideoUrls` + hôte public supprimés.
- **Page `/watch` réécrite en page web authentifiée** (Firebase Auth JS : Google +
  e-mail/mdp + création de compte). Config web injectée via env
  `FIREBASE_WEB_API_KEY` / `FIREBASE_WEB_APP_ID` (projet `bloom-bcb1f`).
- ⚠️ **Photos encore exposées** via leurs URLs tokenisées Firebase (même faille
  que les vidéos avant — **Phase 3** : signer via Admin SDK + migrer les chemins).

### Visualiseur plein écran réutilisable
- `lib/core/widgets/media_fullscreen_viewer.dart` : photos (zoom) + vidéos
  (lecture), fichiers **locaux ET distants**. Vignettes photo/vidéo cliquables dans
  l'écran de création/édition.

### Lot produit / UX
- **Paiement MVP** : on reste « facture à réception », clarifié en **paiement TWINT
  après livraison, détails par e-mail** — messages ajoutés (écran confirmation +
  suivi de commande). Stripe abandonné pour le MVP (`paymentEnabled` reste `false`).
- **Touche retour** (Android) sur le dashboard carnet → revient à `/home` (PopScope).
- **Dashboard** : widget « Anecdotes » retiré ; CTA livre → « **un livre fait au
  minimum 29 pages** » (fin du palier « 10 souvenirs »).
- **Quotas** : **quota audio** ajouté (15 / 150) ; **compteurs photos + vidéos +
  vocaux** sur l'accueil + alerte premium + **blocage à l'enregistrement** du mémo.
- **Type de carnet par défaut = Famille**.
- **Nouveau type « Moi / Adulte »** (`moi`, flag `hasWeightTracking`) → courbe de
  **suivi de poids** (sans référentiel OMS).

### Refonte de la courbe de croissance (l'écran s'affichait vide)
- L'écran lisait les collections **legacy** `children`/`milestones`. Refondu sur
  `notebooks`/`memories` (type `taille_poids`). **Enfant** = courbe **OMS**
  taille + poids + toise visuelle ; **carnet Moi** = courbe de poids simple. Saisie
  depuis l'écran (commentaire → l'IA extrait → souvenir `taille_poids`) **en plus**
  du nouveau souvenir. Route `/notebook/:id/growth` (param `notebookId`).

### Doc
- `docs/Carnet-fonctionnement.pdf` (15 pages) : explicatif par section + **étude de
  marché** (freemium/tarifs, positionnement, concurrents, différenciateurs),
  renommé « **Carnet** », flux paiement = **facture TWINT**, et **section « Suivi de
  croissance (enfant) »**. Régénérable : `docs/_pdfbuild/build.js`
  (`npm i pdfkit && node build.js`).

### ⬜ À tester sur device (lot 23.06)
- [ ] Vidéo : enregistrer → upload OK ; lecture in-app (membre) ; `/watch` après login
- [ ] Collaborateur sur **nouveau build** revoit les vidéos partagées
- [ ] Compteurs photos/vidéos/vocaux + blocage premium
- [ ] Courbe **enfant** (OMS + toise) ; carnet **Moi** → courbe poids ; saisie depuis l'écran
- [ ] Création carnet : « Famille » présélectionné ; type « Moi » disponible

## ✅ Fait (21.06.2026) — Vidéos multiples par souvenir + lecture inline

- **Modèle** (`memory_model.dart`) : `videoKey` (unique) → **`videoKeys` (liste)**
  + `videoDurationsMs`, avec **compat ascendante** (lecture de l'ancien
  `videoKey`) et **miroir hérité** écrit en base (`videoKey`/`videoDurationMs` =
  1er élément) pour ne casser aucun ancien client ni QR déjà imprimé.
- **Ajout** (`memory_create_screen.dart`) : galerie de vignettes vidéo façon
  photos (▶ + durée + suppression), **max 3/souvenir** (`maxVideosPerMemory`) en
  plus du quota global (15 gratuit / 150 premium). Mention des conditions
  affichée à l'utilisateur.
- **Lecture** (`memories_list_screen.dart`) : `_PhotoViewer` → **`_MediaViewer`**
  unifié (photos zoomables + **vidéos jouées inline** via `video_player`),
  balayables ensemble ; pause auto au swipe. Vignette de souvenir : badge ▶ N si
  vidéos, placeholder sombre si souvenir sans photo. Idem mini-vignette du
  dashboard (`_MemoryPreviewTile`).
- **File d'upload** (`media_upload_queue.dart`) : upload des N vidéos
  **SÉQUENTIEL** — `video_compress` n'a qu'une session de compression globale,
  le parallèle faisait échouer toutes les compressions (= clips non sauvegardés,
  le bug initial). Échec partiel désormais **visible** (bannière « Réessayer »)
  et re-mis en file **sans doublon** (seuls les clips manquants).
- **Quota** (`quota_service.dart`) : comptage **total** des vidéos (somme des
  clés, pas des souvenirs) + constante `maxVideosPerMemory = 3`.
- **Livre** (`book_pdf_service.dart`) : **1 seul QR par souvenir → galerie** ;
  libellés au pluriel quand >1 vidéo.
- **Backend** : `api/watch.ts` liste **toutes** les vidéos d'un souvenir
  (`videoKeys`, repli `videoKey`). **Route dynamique `api/video/[action].ts`**
  regroupe `upload-url`, `delete` et **`config`** (l'app appelle
  `/api/video/config` pour récupérer `R2_PUBLIC_HOST` et reconstruire les URLs de
  lecture — l'hôte n'est jamais codé en dur dans l'app).
- **Nouveau package** : `video_player: ^2.9.2`.
- ⚠️ **Dette** : l'URL `pub-….r2.dev` (R2 public dev) est limitée en débit →
  brancher un **domaine personnalisé** sur le bucket pour la prod (changer
  `R2_PUBLIC_HOST` + redéployer suffit, rien d'autre ne casse). Les vignettes
  vidéo de l'écran d'ajout sont des cartes sombres génériques (pas une image
  extraite) — possible amélioration via `video_compress` thumbnail.

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
  - **Deux chemins de partage** : « Inviter par email » → `/api/email/share` via
    **Resend** ; « Créer un lien » → deep link partagé soi-même (pas d'email).
  - ⚠️ Sans app installée : 2 étapes (installer → rouvrir le lien). Le
    « install → rejoint auto » (deferred deep link) nécessiterait Branch/Adjust
    ou des App Links (https vérifiés) — plus tard.
- **« Partagé avec »** sur le dashboard du carnet : avatars + nombre (+ en
  attente), tap → sheet de gestion. Sinon « Partager ce carnet ».
- **Distribution app** (discuté) : aujourd'hui APK direct
  (`dmathys.dev/download/carnet.apk`, Android sideload). Reco : Firebase App
  Distribution pour la beta, Play Store/App Store pour le public.

## ✅ Fait (16.06.2026, suite 4) — Paiement (codé, désactivé)

- **Paiement TWINT via Stripe Checkout** entièrement codé mais **désactivé** :
  on reste en **facture / « à réception »** pour démarrer (`AppConfig.paymentEnabled = false`).
- Backend (déployé, env-gated sur `STRIPE_SECRET_KEY`) :
  - `/api/payment/checkout` (auth, propriétaire) : crée une session Stripe
    (TWINT + carte, CHF, **montant = `order.price`** — prix variable selon le
    nombre de pages/photos), renvoie l'URL hébergée.
  - `/api/payment/success` : revérifie le paiement auprès de Stripe puis marque
    la commande `paid`.
- App : `OrderService.createCheckout`, bouton **« Payer avec TWINT »** sur le
  suivi de commande (masqué tant que `paymentEnabled = false`).
- **Pour activer plus tard** : `STRIPE_SECRET_KEY` dans Vercel + activer TWINT
  dans Stripe + `paymentEnabled = true` (1 ligne) + rebuild. Compte Stripe
  **individuel** suffit (pas de société). TVA non requise sous CHF 100k/an (CH).
- ⚠️ Manque pour fiabilité totale si activé : **webhook Stripe** (cas où le
  client ferme le navigateur avant le retour sur la page de succès).

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
  `GELATO_PRODUCT_UID_SOFT`, `GELATO_PRODUCT_UID_HARD`,
  `R2_ACCOUNT_ID`, `R2_BUCKET` (=`carnet-videos`), `R2_ACCESS_KEY_ID`,
  `R2_SECRET_ACCESS_KEY`, `R2_PUBLIC_HOST`, `FIREBASE_WEB_API_KEY`,
  `FIREBASE_WEB_APP_ID` (config Firebase web pour `/watch`), `STRIPE_SECRET_KEY`
  (paiement désactivé pour le MVP)
- **Routes backend** : `/api/ai/chat`, `/api/email/order`, `/api/email/share`,
  `/listen` (→ `/api/listen`, mémo vocal public), `/api/gelato/order` (admin),
  `/api/video/[action]` (`upload-url`, `delete`, `config`, **`play`** = lecture
  signée membre-only), `/watch` (page web **authentifiée**, QR vidéo),
  `/api/payment/*` (Stripe, désactivé MVP)
- **Collections Firestore** : `notebooks`, `memories`, `orders`,
  `generatedBooks` (historique PDF), `books` (histoires IA legacy), `users`,
  `aiUsage`, + legacy `children`/`milestones`
- **Console admin** : route `/admin/orders` (changer statut, télécharger PDF,
  envoyer à Gelato)
- Format livre PDF : **21×28 cm + 4 mm bleed** (Gelato softcover). Photos
  compressées à 2048 px ⇒ ~170 DPI en pleine page (> min Gelato 150, < 300
  premium — plafond ajustable dans `photo_service.dart` si besoin print HD).
