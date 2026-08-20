/// Templates de collage pour le poster (produit "Art print with hanger").
/// Volontairement un petit catalogue fixe (pas d'éditeur libre) — voir le
/// plan `eager-pondering-pony.md` §2. Choisi par `buildPosterLayout` selon
/// le nombre de photos et le nombre de photos marquées "en vedette".
library;

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

/// Cap dur : au-delà, pas de nouveau template — la sélection doit être
/// bloquée en amont (voir poster_select_screen.dart).
const int posterMaxPhotos = 6;

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

  // 5-6 photos : grille égale, la mise en avant est ignorée (message dédié
  // côté UI — voir poster_generate_screen.dart).
  if (photoCount == 5) {
    return const PosterLayout(
      tiles: [
        PosterTile(0, 0, 1 / 3, 0.5, TileRole.small),
        PosterTile(1 / 3, 0, 1 / 3, 0.5, TileRole.small),
        PosterTile(2 / 3, 0, 1 / 3, 0.5, TileRole.small),
        PosterTile(0, 0.5, 0.5, 0.5, TileRole.small),
        PosterTile(0.5, 0.5, 0.5, 0.5, TileRole.small),
      ],
      orientation: PosterOrientation.portrait,
      templateName: 'gridSmall',
    );
  }

  return const PosterLayout(
    tiles: [
      PosterTile(0, 0, 1 / 3, 0.5, TileRole.small),
      PosterTile(1 / 3, 0, 1 / 3, 0.5, TileRole.small),
      PosterTile(2 / 3, 0, 1 / 3, 0.5, TileRole.small),
      PosterTile(0, 0.5, 1 / 3, 0.5, TileRole.small),
      PosterTile(1 / 3, 0.5, 1 / 3, 0.5, TileRole.small),
      PosterTile(2 / 3, 0.5, 1 / 3, 0.5, TileRole.small),
    ],
    orientation: PosterOrientation.portrait,
    templateName: 'gridSmall',
  );
}
