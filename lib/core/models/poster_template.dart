/// Templates de collage pour le tirage à accrocher. 1 à 4 photos : gabarits
/// fixes avec une photo "en vedette" possible. 5 photos et au-delà : grille
/// qui s'adapte automatiquement au nombre exact de photos (voir
/// `_adaptiveGridTiles`) — pas de palier fixe ni de plafond de design, voir
/// `posterMaxPhotos` pour le seul plafond restant (pratique, pas visuel).
library;

import 'dart:math' show sqrt;

enum PosterOrientation { portrait, landscape }

enum TileRole { full, large, small }

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

/// Plafond pratique (pas un choix de design) : au-delà, une grille de photos
/// devient illisible et le téléchargement/traitement de toutes les images à
/// chaque étape (aperçu, contrôle qualité, PDF) devient lourd. En dessous de
/// ce nombre, la grille (voir `_gridLayout`) s'adapte automatiquement à
/// n'importe quel nombre de photos — pas de palier fixe comme avant.
const int posterMaxPhotos = 20;

/// Construit la disposition pour `photoCount` photos, `featured` étant
/// l'ensemble des INDEX (dans la liste de photos) marqués "en vedette".
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

  // 5 photos et au-delà : grille qui s'adapte au nombre exact de photos
  // (pas de palier fixe) — la mise en avant est ignorée (message dédié côté
  // UI, voir poster_generate_screen.dart). Plus il y a de photos, plus
  // chaque case est petite — ce qui, via PosterQualityService, débloque
  // souvent des formats plus grands qu'une seule photo plein cadre ne le
  // permettrait (chaque case demande moins de pixels).
  return PosterLayout(
    tiles: _adaptiveGridTiles(photoCount),
    orientation: PosterOrientation.portrait,
    templateName: 'gridSmall',
  );
}

/// Grille égale adaptée à `n` photos : colonnes = ⌈√n⌉, lignes = ⌈n/colonnes⌉,
/// la dernière ligne (éventuellement incomplète) répartit SES cases sur toute
/// la largeur plutôt que de laisser un trou. Se réduit exactement aux anciens
/// gabarits fixes pour n=5 (3+2) et n=6 (3×2) — généralisé à tout n>4.
List<PosterTile> _adaptiveGridTiles(int n) {
  final cols = sqrt(n).ceil();
  final rows = (n / cols).ceil();
  final tiles = <PosterTile>[];
  var remaining = n;
  for (var row = 0; row < rows; row++) {
    final itemsInRow = remaining < cols ? remaining : cols;
    final tileW = 1 / itemsInRow;
    final tileH = 1 / rows;
    for (var col = 0; col < itemsInRow; col++) {
      tiles.add(PosterTile(col * tileW, row * tileH, tileW, tileH, TileRole.small));
    }
    remaining -= itemsInRow;
  }
  return tiles;
}
