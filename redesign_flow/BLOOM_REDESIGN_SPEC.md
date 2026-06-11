# Bloom — Spec redesign : Carnets génériques + Dashboard

> **Objectif** : Faire évoluer Bloom d'une app "journal enfant" vers une plateforme de carnets de souvenirs multi-use-cases, avec génération de livres imprimés comme moteur de monétisation.
> **Modèle d'inspiration** : Famileo (gazette papier familiale) — même logique contenu digital → objet physique → abonnement/commande récurrente.

---

## 1. Contexte & architecture actuelle

### Ce qui existe déjà (à conserver / refactoriser)
- Auth : Google Sign-In (Firebase Auth)
- Base de données : Firestore (`bloom-bcb1f`, europe-west)
- Modèle de données : `children/{childId}` → `memories/{memoryId}`
- Typage des souvenirs : `taille_poids`, `anecdote`, `premier_mouvement`, `premiere_parole`, `grande_reussite`
- Composant animal compagnon (Renard, Lapin, Ours, Dinosaure, Pingouin, Souris)
- Courbes de croissance OMS (P3, P50, P97)
- Saisie IA : texte libre → classification automatique

### Ce qui change
- Le concept "enfant" devient "carnet" (générique)
- Un carnet a un **type** (template)
- Le compagnon animal devient optionnel, uniquement pour le type `enfant`
- Ajout d'un **dashboard** après ouverture d'un carnet
- La génération de livre devient un flow explicite avec options de commande

---

## 2. Modèle de données cible (Firestore)

### Collection `notebooks` (remplace `children`)

```
notebooks/{notebookId}
  ├── userId: string
  ├── type: "enfant" | "voyage" | "famille" | "grossesse" | "scolaire" | "libre"
  ├── title: string                    // "Nathan", "Vacances Croatie 2026", etc.
  ├── subtitle: string                 // optionnel, ex: "5 ans · compagnon Roux"
  ├── coverColor: string               // hex, ex: "#7AAE4A"
  ├── emoji: string                    // emoji représentatif, ex: "🦊"
  ├── companion: string | null         // null sauf type "enfant"
  ├── companionName: string | null
  ├── birthdate: timestamp | null      // pour type "enfant" et "grossesse"
  ├── gender: "boy" | "girl" | null    // pour type "enfant"
  ├── createdAt: timestamp
  ├── updatedAt: timestamp
  └── lastMemoryAt: timestamp | null
```

### Collection `memories` (structure inchangée, sous notebooks)

```
notebooks/{notebookId}/memories/{memoryId}
  ├── type: string                     // catégorie IA ou manuelle
  ├── content: string                  // texte libre
  ├── mediaUrls: string[]              // photos
  ├── aiGenerated: boolean
  ├── date: timestamp
  └── createdAt: timestamp
```

### Collection `books` (nouvelle)

```
books/{bookId}
  ├── notebookId: string
  ├── userId: string
  ├── status: "generating" | "ready" | "ordered" | "shipped"
  ├── pdfUrl: string | null
  ├── memoriesCount: number
  ├── format: "pdf" | "printed" | "gift"
  ├── price: number | null
  ├── orderRef: string | null
  ├── createdAt: timestamp
  └── updatedAt: timestamp
```

---

## 3. Écrans à développer

### 3.1 Home — liste des carnets

**Fichier** : `lib/screens/home_screen.dart`

**État vide** (0 carnets) :
- Icône livre centré
- Titre : "Crée ton premier carnet"
- Sous-titre : "Vacances, enfant, famille… chaque souvenir mérite un livre."
- Bouton primary : "+ Créer un carnet"

**État rempli** (carnets existants) :
- Liste de cards scrollable
- Chaque card : emoji/thumbnail | titre | sous-titre (type · contexte) | dot de statut coloré + texte
- **Statuts dot** :
  - 🟢 vert : actif, souvenirs récents (< 7 jours)
  - 🟡 amber : en cours (7–30 jours)
  - 🔴 rouge : "Livre prêt — commander" (seuil atteint, ex 30+ souvenirs)
- FAB bas-droite : "+ Nouveau carnet"

---

### 3.2 Onboarding carnet — Choix du template

**Fichier** : `lib/screens/notebook_create_template_screen.dart`

Grid 2 colonnes, 6 cards :

| Type | Emoji | Titre | Description |
|------|-------|-------|-------------|
| `enfant` | 🧒 | Carnet enfant | Anecdotes, étapes, croissance |
| `voyage` | 🌴 | Carnet voyage | Destinations, photos, récits |
| `famille` | 👨‍👩‍👧 | Gazette famille | Nouvelles pour les proches |
| `grossesse` | 🤰 | Journal grossesse | 9 mois de souvenirs |
| `scolaire` | 🎓 | Années scolaires | Chaque rentrée immortalisée |
| `libre` | ✨ | Carnet libre | Thème 100% personnalisé |

- Tap → sélection (highlight vert)
- Bouton "Continuer" bas de page

---

### 3.3 Onboarding carnet — Configuration

**Fichier** : `lib/screens/notebook_create_config_screen.dart`

**Champs communs (tous types)** :
- Titre du carnet (text field)
- Couleur de couverture (6 dots colorés)

**Champs conditionnels `enfant`** :
- Prénom de l'enfant (text field)
- Date de naissance (date picker)
- Genre : Garçon / Fille (2 cards visuelles) → pour courbe OMS
- Compagnon animal (chips horizontaux : Renard, Lapin, Ours, Dino, Pingouin, Souris)
- Nom du compagnon (pre-rempli, modifiable)

**Champs conditionnels `voyage`** :
- Destination (text field)
- Dates du voyage (range date picker)

**Champs conditionnels `famille`** :
- Destinataire (text field, ex: "Grand-père Henri")
- Fréquence du livre : Mensuel / Trimestriel / Annuel

**Champs conditionnels `grossesse`** :
- Date prévue d'accouchement (date picker)

Bouton "Créer le carnet" → crée le document Firestore → navigation vers Dashboard

---

### 3.4 Dashboard carnet ⭐ (NOUVEL ÉCRAN)

**Fichier** : `lib/screens/notebook_dashboard_screen.dart`

C'est l'écran central après ouverture d'un carnet. Il remplace le profil enfant actuel et doit afficher :

#### Header
- Titre du carnet (bold, 20px)
- Sous-titre contextuel (type + âge si enfant, destination si voyage, etc.)
- Avatar/emoji du carnet (grand, coloré selon coverColor)

#### CTA Livre (si ≥ 10 souvenirs)
Card amber proéminente :
```
📖  [N] souvenirs capturés
    Ton livre est prêt à générer        [Générer →]
```
→ Navigation vers Screen 3.7 (Génération livre)

#### Stats grid (2×2 ou 2×3)
Métriques adaptées selon le type de carnet :

**Type `enfant`** :
- Total souvenirs
- Mesures (taille/poids)
- Anecdotes
- Dernière saisie (date relative)

**Type `voyage`** :
- Total souvenirs
- Photos
- Jours de voyage
- Destinations

**Type `famille`** :
- Total souvenirs
- Contributeurs
- Prochain livre (date)
- Livres envoyés

**Type générique** :
- Total souvenirs
- Cette semaine
- Dernière saisie
- Livres générés

#### Shortcuts (boutons rapides)
Row de 3 boutons icône+label :
- 📔 Journal (→ liste souvenirs)
- 📊 Stats / Courbes (→ selon type)
- 📖 Livre (→ génération)

#### Derniers souvenirs (aperçu)
3 derniers souvenirs en mini-cards, avec bouton "Voir tout →"

#### FAB
"+ Nouveau souvenir" (vert, bas-droite)

---

### 3.5 Journal — Liste des souvenirs

**Fichier** : `lib/screens/memories_list_screen.dart`

(Adapter l'écran existant)
- Filtre par type de souvenir (chips scrollables en haut)
- Chaque item : type tag | contenu | date relative
- Swipe-to-delete
- CTA livre visible si seuil atteint

---

### 3.6 Saisie souvenir

**Fichier** : `lib/screens/memory_create_screen.dart`

(Garder l'écran existant, adapter le titre selon le type de carnet)
- Titre : "Qu'as-tu à noter ?" (invariant)
- Placeholder adapté au type :
  - `enfant` : "Ex : Léa a dit maman pour la première fois ce matin…"
  - `voyage` : "Ex : On a découvert une crique incroyable près de Split…"
  - `famille` : "Ex : Mamie a fêté ses 80 ans entourée de toute la famille…"
  - `grossesse` : "Ex : Premiers coups de pied ce soir, 22 semaines…"
  - `libre` : "Écris ce qui te tient à cœur…"

---

### 3.7 Génération du livre

**Fichier** : `lib/screens/book_generate_screen.dart`

**Étape 1 — Aperçu**
- Preview livre animé (couverture colorée avec emoji/compagnon)
- Titre auto-généré : "[Prénom] & [Compagnon]\n[Année début] – [Année fin]"
- Nombre de souvenirs inclus
- Barre de progression génération IA (simulée si async)

**Étape 2 — Choix du format**
3 options en cards sélectionnables :

| Format | Icône | Prix | Description |
|--------|-------|------|-------------|
| PDF numérique | 📱 | Gratuit | À partager ou imprimer soi-même |
| Livre imprimé | 📦 | CHF 29.90 | Couverture rigide · livré en 5–7 jours |
| Offrir à un proche | 🎁 | CHF 29.90 | Adresse de livraison différente |

**Étape 3 — Commande**
- Récap commande
- Bouton "Commander · CHF 29.90"
- Mention : "Satisfait ou remboursé · livraison offerte dès 2 livres"
- → Intégration Stripe (à implémenter séparément)

---

## 4. Design system (inchangé)

```
Background : #F5F0E8  (beige chaud)
Primary    : #5E7A42  (vert forêt)
Primary dark : #3D5C25
Accent amber : #C98A1A (CTA livre)
Text primary : #2C2A1E
Text muted   : #888880
Card bg      : #FFFFFF
Border       : #DDD8CC (0.5px)
Border radius card : 14px
Border radius btn  : 50px
Font         : DM Sans (existant)
```

**Couleurs de couverture disponibles** :
```
Vert    : #7AAE4A
Amber   : #C98A1A
Bleu    : #4A8AC9
Rose    : #B94A7A
Violet  : #8A6AAE
Gris    : #888880
```

**Dots de statut** :
```
Actif   : #5E7A42
En cours: #C98A1A
Urgent  : #B94040
```

---

## 5. Navigation (Flutter)

```
HomeScreen
  └── NotebookCreateTemplateScreen
        └── NotebookCreateConfigScreen
              └── NotebookDashboardScreen
                    ├── MemoriesListScreen
                    │     └── MemoryCreateScreen
                    ├── StatsScreen (courbes OMS si type=enfant, sinon stats génériques)
                    └── BookGenerateScreen
                          └── BookOrderScreen (Stripe — à implémenter)
```

---

## 6. Règles de migration

1. **Renommer** la collection Firestore `children` → `notebooks` (migration script ou double-read)
2. **Ajouter le champ `type`** sur les documents existants : valeur par défaut `"enfant"`
3. **Conserver** toute la logique de saisie IA et de classification des souvenirs
4. **Conserver** les courbes de croissance OMS — les afficher uniquement si `notebook.type == "enfant"`
5. **Ne pas casser** les profils existants (Léa, Nathan, Nathan M., Nathan2)

---

## 7. Ordre d'implémentation recommandé

```
Phase 1 — Modèle de données
  [ ] Créer le modèle NotebookModel (remplace ChildModel)
  [ ] Adapter le repository Firestore
  [ ] Migration des données existantes (type = "enfant" par défaut)

Phase 2 — Création de carnet générique
  [ ] NotebookCreateTemplateScreen (choix du type)
  [ ] NotebookCreateConfigScreen (formulaire conditionnel)
  [ ] Mise à jour de HomeScreen (liste carnets générique)

Phase 3 — Dashboard
  [ ] NotebookDashboardScreen (nouvel écran central)
  [ ] Stats grid adaptées au type
  [ ] CTA livre conditionnel

Phase 4 — Livre
  [ ] BookGenerateScreen (aperçu + choix format)
  [ ] Intégration Gelato / Lulu print-on-demand API
  [ ] Intégration Stripe pour le paiement

Phase 5 — Polish
  [ ] Placeholders adaptés au type dans MemoryCreateScreen
  [ ] Animations de couverture livre
  [ ] Notifications : rappels de saisie
```

---

## 8. Fichiers de référence

- `REFERENCE_ecrans_actuels.jpg` — capture des 11 écrans existants
- `REFERENCE_redesign_flow.png` — wireframes cibles des 7 nouveaux écrans
- Ce fichier : `BLOOM_REDESIGN_SPEC.md`

---

*Spec rédigée le 29 mai 2026 — v1.0*
