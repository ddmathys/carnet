# Lingua — carnet de vocabulaire

MVP d'une app pour se perfectionner dans une langue : on choisit la langue, on
note les mots et phrases qu'on ne connaît pas encore, et on les parcourt.

Chaque entrée garde **deux** choses qu'on confond souvent :

| | |
|---|---|
| **Contexte** | la phrase réelle où le mot a été croisé (`Voy al mercado los sábados.`) |
| **Thème** | le classement qu'on lui donne soi-même (`Voyage`, `Boulot`, `Cuisine`…) |

C'est une app **Flutter séparée**, sans rapport avec l'app `bloom`/Carnet à la
racine du dépôt : son propre `pubspec.yaml`, son propre point d'entrée.

## Ce que fait le MVP

- **Choix de la langue** au premier lancement (20 langues), plusieurs langues
  possibles, bascule de l'une à l'autre depuis le titre de l'écran.
- **Ajout d'une entrée** : mot ou phrase, traduction, contexte, thème.
  « Enregistrer et en ajouter un autre » garde le thème pour enchaîner.
- **Parcourir** : liste chronologique (la plus récente en haut), recherche
  libre (mot, traduction, contexte, thème — accents et casse ignorés), filtre
  par thème en un tap.
- **Cartes** (icône en haut à droite) : le paquet filtré, mélangé, la réponse
  au toucher, « à revoir » / « je le sais ».
- **Tout est local** : aucun compte, aucun réseau. Le carnet est un JSON dans
  le stockage de l'appareil (`shared_preferences`).

## Lancer l'app

Le dépôt ne contient que le code Dart et l'enveloppe web : les dossiers de
plateforme sont générés par Flutter.

```bash
cd apps/lingua
flutter create --platforms=android,ios,web .   # une seule fois
flutter pub get
flutter run            # ou : flutter run -d chrome
```

Tests :

```bash
cd apps/lingua
flutter test
```

## Organisation du code

```
lib/
  main.dart                     charge le carnet, puis lance l'app
  app.dart                      thème + aiguillage (langue choisie ? → carnet)
  core/
    models/language.dart        les langues proposées
    models/vocab_entry.dart     une entrée + la recherche (sans accents)
    storage/key_value_store.dart  stockage clé/valeur (device ou mémoire pour les tests)
    store/vocab_store.dart      tout l'état + la persistance JSON
    store/store_scope.dart      accès au store depuis n'importe quel écran
  features/
    onboarding/                 choix de la langue
    entries/                    carnet, carte d'une entrée, formulaire
    review/                     parcours en cartes
```

Le filtrage est une fonction pure (`VocabStore.filterEntries`) : c'est elle que
les tests vérifient, sans passer par l'interface.

## Suites possibles

- Synchronisation multi-appareils (aujourd'hui : local uniquement).
- Révision espacée (dates de révision plutôt qu'un simple « acquis »).
- Import depuis une photo ou un texte collé (repérer les mots inconnus).
- Prononciation (audio) et exemples générés.
