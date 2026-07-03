# ⚙️ Setup sur une nouvelle machine (rappel)

Ces fichiers **ne sont PAS dans git** (ignorés volontairement car secrets/binaires).
Il faut les recopier manuellement depuis un PC qui les a, sinon l'app ne build/run pas.

## Fichiers à recopier à la main

| Fichier | Emplacement | Rôle |
|---|---|---|
| `bloom-bcb1f-firebase-adminsdk-fbsvc-c89fdb87e6.json` | racine du projet | Clé de service Firebase Admin (backend/scripts) |
| `google-services.json` | `android/app/` | Config Firebase Android (obligatoire pour build) |
| `gemma3-1b-it-int4.task` | racine du projet | Modèle LLM embarqué (gros binaire, non versionné) |

> ℹ️ Aucun `.env` n'existe actuellement dans le projet. S'il en apparaît un plus tard, il sera aussi ignoré → à recopier.

## Comment les transférer

- Clé USB / cloud perso (Drive, etc.) — **jamais** les pousser sur GitHub.
- Ou les re-télécharger depuis la console Firebase :
  - `google-services.json` → Firebase Console → Paramètres projet → app Android
  - clé admin SDK → Firebase Console → Paramètres → Comptes de service → *Générer une nouvelle clé*
  - modèle `.task` → depuis Firebase Storage où il est hébergé

## Étapes après `git clone`

```bash
git clone https://github.com/ddmathys/carnet.git
cd carnet
# … recopier les 3 fichiers ci-dessus …
flutter pub get
flutter run
```
