# Moteur de mise en page A4 — notes d'implémentation

Implémentation de la spec « Moteur de mise en page A4 pour Carnet.pdf » dans
`lib/core/services/book_pdf_service.dart`.

## Conforme à la spec
- 1 souvenir à la fois, jamais 2 souvenirs sur une même page.
- Séparation **verticales** (h > w) / **horizontales** (w ≥ h).
- Pages **verticales d'abord**, puis **horizontales**.
- 6 templates : `V4` (≥4 → grille 2×2), `V3` (3 → 1 grande + 2), `V2` (2 →
  empilées), `V1` (1 → pleine surface) ; `H2` (≥2 → 2 empilées), `H1` (1 →
  pleine surface). Algo glouton identique aux exemples (9→4/4/1, etc.).
- Images **bord à bord** (full-bleed) : `_pageMargin` = 0 et `_gap` = 0 (aucune
  marge ni liseré blanc). Ratio conservé + `cover`. Mettre une valeur > 0
  réintroduit une marge/espacement crème uniforme.

## Scénarios non couverts par la spec (choix faits ici)
- **Légendes** (date + titre + description du souvenir) : la spec ne traite que
  les photos (« page avec texte + photos » est listée en évolution future). →
  carte légende posée en **haut-gauche de la 1ʳᵉ page** du souvenir. Affichée
  même sans texte (au moins la date), via le flag `_PhotoPageEntry.showCaption`.
- **QR média** : non prévu par la spec. → 1 seul QR par souvenir, sur la
  **dernière page** du souvenir, bas-gauche. Cible `/<backend>/watch?m=<id>`
  (page authentifiée listant **toutes** les vidéos du souvenir).
- **Souvenirs sans photo** : pages texte dédiées (hors moteur photo).
- **Proportions V3** : non spécifiées → grande photo = 56 % de la hauteur utile.

## Réglages rapides
- Bord à bord (défaut) : `_pageMargin = 0`, `_gap = 0`.
- Pour réintroduire un liseré album : remonter `_pageMargin` / `_gap`.
- Nouveau template : ajouter une valeur à l'enum `_Tpl` + un `case` dans
  `_photoPage` (le reste de l'algo ne change pas — catalogue extensible).
