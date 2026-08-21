/// Templates de collage pour le tirage à accrocher. 1 à 4 photos : gabarits
/// fixes avec une photo « en vedette » possible. 5 photos et au-delà :
/// MOSAÏQUE qui s'adapte au nombre exact de photos ET aux photos mises en
/// avant — une vedette occupe un bloc 2×2 (4× la surface d'une case normale),
/// autant de vedettes qu'on veut, pas de palier fixe.
///
/// Le collage ne décide PAS de la taille du papier : c'est l'inverse. La
/// taille des cases (donc le nombre de photos) impose un format minimum —
/// voir `poster_format_rules.dart`. `posterMaxPhotos` est le seul plafond
/// restant (pratique, pas visuel).
library;

import 'dart:math' show sqrt;

enum PosterOrientation { portrait, landscape }

enum TileRole { full, large, small }

/// Fraction de la hauteur de page réservée à la bande légende + QR code.
/// Partagée par le PDF (`PosterPdfService`) et par le calcul du format
/// minimum (`PosterFormatRules`) : les cases ne disposent que du reste.
const double posterBandFraction = 0.09;

/// Position/taille d'une case, en fractions [0,1] du canevas (indépendant de
/// la taille physique réelle — appliqué au format A choisi à la génération).
class PosterTile {
  final double x, y, w, h;
  final TileRole role;
  const PosterTile(this.x, this.y, this.w, this.h, this.role);
}

class PosterLayout {
  /// Une case par photo, MÊME ORDRE que la liste de photos fournie.
  final List<PosterTile> tiles;
  final PosterOrientation orientation;
  final String templateName;
  const PosterLayout({
    required this.tiles,
    required this.orientation,
    required this.templateName,
  });
}

/// Plafond pratique (pas un choix de design) : au-delà, télécharger et
/// embarquer toutes les images à chaque étape (aperçu, contrôle qualité, PDF)
/// devient trop lourd pour un téléphone. Côté rendu, rien ne casse : la
/// mosaïque s'adapte à n'importe quel nombre, et c'est le FORMAT qui grandit
/// avec la densité du collage (voir `PosterFormatRules`) — à 50 photos on est
/// déjà en A0.
const int posterMaxPhotos = 50;

/// Construit la disposition pour `photoCount` photos, `featured` étant
/// l'ensemble des INDEX (dans la liste de photos) marqués « en vedette ».
PosterLayout buildPosterLayout(int photoCount, Set<int> featured) {
  assert(photoCount >= 1 && photoCount <= posterMaxPhotos);

  if (photoCount == 1) {
    return const PosterLayout(
      tiles: [PosterTile(0, 0, 1, 1, TileRole.full)],
      // Le portrait est le choix par défaut le plus courant pour une seule
      // photo (le sélecteur de taille laisse de toute façon choisir paysage
      // si l'utilisateur préfère — voir poster_generate_screen.dart).
      orientation: PosterOrientation.portrait,
      templateName: 'single',
    );
  }

  if (photoCount == 2) {
    final oneFeatured = featured.length == 1;
    if (oneFeatured) {
      final f = featured.first;
      final tiles = List<PosterTile>.filled(2, const PosterTile(0, 0, 0, 0, TileRole.small));
      for (var i = 0; i < 2; i++) {
        tiles[i] = i == f
            ? const PosterTile(0, 0, 0.65, 1, TileRole.large)
            : const PosterTile(0.65, 0, 0.35, 1, TileRole.small);
      }
      return PosterLayout(
          tiles: tiles, orientation: PosterOrientation.landscape, templateName: 'duoFeatured');
    }
    return const PosterLayout(
      tiles: [
        PosterTile(0, 0, 0.5, 1, TileRole.large),
        PosterTile(0.5, 0, 0.5, 1, TileRole.large),
      ],
      orientation: PosterOrientation.landscape,
      templateName: 'duoEqual',
    );
  }

  if (photoCount == 3) {
    // Vedette par défaut = 1ʳᵉ photo si aucune cochée (reste à 6 templates).
    final f = featured.length == 1 ? featured.first : 0;
    final tiles = <PosterTile>[];
    final smallSlots = [for (var i = 0; i < 3; i++) if (i != f) i];
    for (var i = 0; i < 3; i++) {
      if (i == f) {
        tiles.add(const PosterTile(0, 0, 0.6, 1, TileRole.large));
      } else {
        final slot = smallSlots.indexOf(i);
        tiles.add(PosterTile(0.6, slot * 0.5, 0.4, 0.5, TileRole.small));
      }
    }
    return PosterLayout(
        tiles: tiles, orientation: PosterOrientation.portrait, templateName: 'trioFeatured');
  }

  if (photoCount == 4) {
    final oneFeatured = featured.length == 1;
    if (oneFeatured) {
      final f = featured.first;
      final tiles = <PosterTile>[];
      final smallSlots = [for (var i = 0; i < 4; i++) if (i != f) i];
      for (var i = 0; i < 4; i++) {
        if (i == f) {
          tiles.add(const PosterTile(0, 0, 0.55, 1, TileRole.large));
        } else {
          final slot = smallSlots.indexOf(i);
          tiles.add(PosterTile(0.55, slot / 3, 0.45, 1 / 3, TileRole.small));
        }
      }
      return PosterLayout(
          tiles: tiles, orientation: PosterOrientation.portrait, templateName: 'quadFeatured');
    }
    return const PosterLayout(
      tiles: [
        PosterTile(0, 0, 0.5, 0.5, TileRole.small),
        PosterTile(0.5, 0, 0.5, 0.5, TileRole.small),
        PosterTile(0, 0.5, 0.5, 0.5, TileRole.small),
        PosterTile(0.5, 0.5, 0.5, 0.5, TileRole.small),
      ],
      orientation: PosterOrientation.portrait,
      templateName: 'quadGrid',
    );
  }

  // 5 photos et au-delà : mosaïque adaptée au nombre exact de photos et aux
  // vedettes choisies (pas de palier fixe). Plus il y a de photos, plus
  // chaque case est petite — ce qui, via PosterQualityService, débloque
  // souvent des formats plus grands qu'une seule photo plein cadre ne le
  // permettrait (chaque case demande moins de pixels), et ce qui, via
  // PosterFormatRules, IMPOSE d'ailleurs un format plus grand.
  final hasFeatured = featured.any((i) => i >= 0 && i < photoCount);
  return PosterLayout(
    tiles: _mosaicTiles(photoCount, featured),
    orientation: PosterOrientation.portrait,
    templateName: hasFeatured ? 'mosaicFeatured' : 'gridSmall',
  );
}

/// Mosaïque de `n` photos sur une grille de ⌈√(cases)⌉ colonnes : une photo
/// en vedette occupe un bloc 2×2, les autres une case.
///
/// Règles de remplissage, dans l'ordre :
///  1. les vedettes sont posées en premier (donc en haut), les autres
///     bouchent ensuite les cases libres ligne par ligne ;
///  2. une ligne que ne traverse aucun bloc 2×2 et qui reste incomplète
///     (typiquement la dernière) répartit SES cases sur toute la largeur ;
///  3. les cases encore vides — les blocs 2×2 ne pavent pas toujours
///     parfaitement la grille — sont absorbées par la photo du dessus, sinon
///     par celle de gauche, plutôt que de laisser un trou dans le collage.
///
/// Sans vedette (ou si TOUTES le sont, ce qui revient au même), se réduit
/// exactement à la grille égale d'avant : ⌈√n⌉ colonnes, dernière ligne
/// étalée sur toute la largeur.
List<PosterTile> _mosaicTiles(int n, Set<int> featured) {
  final heroes = <int>{
    for (var i = 0; i < n; i++) if (featured.contains(i)) i,
  };
  // Tout mettre en avant revient à ne rien mettre en avant.
  final useHeroes = heroes.length == n ? const <int>{} : heroes;

  final cellCount = 4 * useHeroes.length + (n - useHeroes.length);
  var cols = sqrt(cellCount).ceil();
  if (cols < 2) cols = 2;

  // owner[ligne][colonne] = index de la photo occupant la case (null = vide).
  final owner = <List<int?>>[];
  void ensureRows(int count) {
    while (owner.length < count) {
      owner.add(List<int?>.filled(cols, null));
    }
  }

  // Rectangle EN CASES de chaque photo : [ligne, colonne, largeur, hauteur].
  final rect = List<List<int>>.generate(n, (_) => [0, 0, 1, 1]);

  bool isFree(int r, int c, int w, int h) {
    for (var rr = r; rr < r + h; rr++) {
      for (var cc = c; cc < c + w; cc++) {
        if (owner[rr][cc] != null) return false;
      }
    }
    return true;
  }

  void place(int i, int r, int c, int w, int h) {
    for (var rr = r; rr < r + h; rr++) {
      for (var cc = c; cc < c + w; cc++) {
        owner[rr][cc] = i;
      }
    }
    rect[i] = [r, c, w, h];
  }

  final order = [
    for (var i = 0; i < n; i++) if (useHeroes.contains(i)) i,
    for (var i = 0; i < n; i++) if (!useHeroes.contains(i)) i,
  ];
  for (final i in order) {
    final span = useHeroes.contains(i) ? 2 : 1;
    var done = false;
    for (var r = 0; !done; r++) {
      // Une ligne vierge accueille toujours un bloc (span ≤ 2 ≤ cols) :
      // la boucle se termine forcément.
      ensureRows(r + span);
      for (var c = 0; c + span <= cols; c++) {
        if (!isFree(r, c, span, span)) continue;
        place(i, r, c, span, span);
        done = true;
        break;
      }
    }
  }
  final rows = owner.length;

  // Règle 2 : lignes incomplètes composées uniquement de cases simples.
  final stretchedRows = <int>{};
  for (var r = 0; r < rows; r++) {
    final ids = <int>{for (final o in owner[r]) if (o != null) o};
    if (ids.isEmpty || ids.length >= cols) continue;
    if (ids.any((i) => rect[i][2] > 1 || rect[i][3] > 1)) continue;
    // Avec des vedettes, on n'étire pas une ligne quasi vide : une photo
    // restante seule sur sa ligne deviendrait une bande pleine largeur, donc
    // PLUS grande que la vedette. Au-delà du double de sa largeur normale, la
    // ligne est laissée à la règle 3 (absorption par les voisines).
    if (useHeroes.isNotEmpty && ids.length * 2 < cols) continue;
    stretchedRows.add(r);
  }

  // Règle 3 : absorption des cases restées vides.
  var changed = true;
  while (changed) {
    changed = false;
    for (var r = 0; r < rows; r++) {
      if (stretchedRows.contains(r)) continue;
      for (var c = 0; c < cols; c++) {
        if (owner[r][c] != null) continue;
        final above = r > 0 ? owner[r - 1][c] : null;
        if (above != null) {
          final t = rect[above];
          if (t[0] + t[3] == r && isFree(r, t[1], t[2], 1)) {
            place(above, t[0], t[1], t[2], t[3] + 1);
            changed = true;
            continue;
          }
        }
        final left = c > 0 ? owner[r][c - 1] : null;
        if (left != null) {
          final t = rect[left];
          if (t[1] + t[2] == c && isFree(t[0], c, 1, t[3])) {
            place(left, t[0], t[1], t[2] + 1, t[3]);
            changed = true;
          }
        }
      }
    }
  }

  // Photos d'une ligne étirée, de gauche à droite.
  final stretchOrder = <int, List<int>>{};
  for (final r in stretchedRows) {
    final ids = <int>[];
    for (var c = 0; c < cols; c++) {
      final o = owner[r][c];
      if (o != null && !ids.contains(o)) ids.add(o);
    }
    stretchOrder[r] = ids;
  }

  final tiles = <PosterTile>[];
  for (var i = 0; i < n; i++) {
    final t = rect[i];
    final ids = stretchOrder[t[0]];
    if (ids != null) {
      final w = 1 / ids.length;
      tiles.add(PosterTile(ids.indexOf(i) * w, t[0] / rows, w, 1 / rows, TileRole.small));
    } else {
      tiles.add(PosterTile(
        t[1] / cols,
        t[0] / rows,
        t[2] / cols,
        t[3] / rows,
        t[2] > 1 || t[3] > 1 ? TileRole.large : TileRole.small,
      ));
    }
  }
  return tiles;
}
