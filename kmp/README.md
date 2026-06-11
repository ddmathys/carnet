# Bloom Web — Kotlin Multiplatform (Compose for Web / WasmJS)

Version web de l'application Bloom, portée depuis Flutter en Kotlin Multiplatform avec Compose for Web (WasmJS).

## Architecture

```
kmp/
├── composeApp/
│   └── src/
│       ├── commonMain/kotlin/com/bloom/     # Code partagé (UI + logique)
│       │   ├── App.kt                        # Entrée Compose
│       │   ├── core/
│       │   │   ├── config/AppConfig.kt       # Clés API
│       │   │   ├── theme/AppTheme.kt         # Couleurs + typographie
│       │   │   ├── models/                   # ChildModel, MilestoneModel, etc.
│       │   │   ├── services/                 # Firebase REST, DeepSeek, Claude
│       │   │   ├── constants/                # Animals, MilestoneTypes
│       │   │   ├── data/GrowthData.kt        # Courbes OMS 2006
│       │   │   └── utils/DatePrecision.kt    # Formatage dates (FR)
│       │   └── features/
│       │       ├── navigation/AppRouter.kt   # Router stack-based
│       │       ├── auth/                     # Connexion / inscription
│       │       ├── children/                 # Liste enfants, timeline, résumé
│       │       ├── milestones/               # Ajout souvenir (IA), graphiques
│       │       ├── story/                    # Génération histoire IA
│       │       ├── growth/                   # Courbes de croissance
│       │       └── profile/                  # Profil utilisateur
│       └── wasmJsMain/kotlin/com/bloom/
│           └── main.kt                       # Point d'entrée navigateur
```

## Prérequis

- **JDK 17+** 
- **Node.js 18+** (pour le build WasmJS)

## Configuration — OBLIGATOIRE avant de lancer

### 1. Firebase Web API Key
Dans `core/config/AppConfig.kt`, remplace :
```kotlin
const val FIREBASE_WEB_API_KEY = "TODO_SET_FROM_FIREBASE_CONSOLE"
```
Par ta clé depuis : **Firebase Console → Project Settings → General → Web API Key**

Le projet Firebase est `bloom-bcb1f`.

### 2. Clé Claude (optionnel)
```kotlin
const val CLAUDE_API_KEY = ""  // Mets ta clé Anthropic ici
```

La clé DeepSeek est déjà configurée (portée depuis Flutter).

## Lancer en développement

```bash
cd kmp
./gradlew :composeApp:wasmJsBrowserDevelopmentRun
```

Ouvre **http://localhost:8080** dans ton navigateur.

## Build de production

```bash
cd kmp
./gradlew :composeApp:wasmJsBrowserDistribution
```

Les fichiers statiques sont dans `composeApp/build/dist/wasmJs/productionExecutable/`.

## Déploiement (Firebase Hosting / Vercel / Netlify)

Déploie le contenu du dossier `productionExecutable/` comme un site statique.

### Vercel
```bash
cd kmp/composeApp/build/dist/wasmJs/productionExecutable
npx vercel deploy
```

### Firebase Hosting
```bash
firebase deploy --only hosting
```
(configure `public: "kmp/composeApp/build/dist/wasmJs/productionExecutable"` dans `firebase.json`)

## Différences avec la version Flutter

| Feature           | Flutter     | Web KMP             |
|-------------------|-------------|---------------------|
| Voice input       | ✅          | ❌ (texte uniquement) |
| OCR caméra        | ✅          | ❌ (texte uniquement) |
| Google Sign-In    | ✅          | ⚠️ (à implémenter)  |
| Firebase Realtime | ✅ Stream   | 🔄 Polling manuel    |
| Charts OMS        | fl_chart    | Compose Canvas       |

## Stack technique

- **Kotlin 2.1.0** + Kotlin Multiplatform
- **Compose Multiplatform 1.7.3** (Compose for Web / WasmJS)
- **Ktor 3.0.3** — HTTP client (Firebase REST, DeepSeek, Claude)
- **kotlinx.serialization 1.7.3** — JSON
- **kotlinx.datetime 0.6.2** — Dates multiplateforme
- **Firebase REST API** — Auth + Firestore (sans SDK natif)
