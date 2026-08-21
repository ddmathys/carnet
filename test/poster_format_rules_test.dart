import 'package:flutter_test/flutter_test.dart';
import 'package:bloom/core/models/poster_template.dart';
import 'package:bloom/core/services/poster_format_rules.dart';
import 'package:bloom/core/services/poster_pricing.dart';

void main() {
  group('mosaïque avec photos en avant', () {
    /// Vérifie que les cases pavent EXACTEMENT le canevas : aucune surface
    /// perdue (trou crème à l'impression) et aucun recouvrement.
    void expectExactTiling(PosterLayout layout, {required String reason}) {
      var area = 0.0;
      for (final t in layout.tiles) {
        expect(t.w, greaterThan(0), reason: reason);
        expect(t.h, greaterThan(0), reason: reason);
        expect(t.x + t.w, lessThanOrEqualTo(1.0000001), reason: reason);
        expect(t.y + t.h, lessThanOrEqualTo(1.0000001), reason: reason);
        area += t.w * t.h;
      }
      expect(area, closeTo(1.0, 1e-9), reason: '$reason : surface couverte');
      for (var i = 0; i < layout.tiles.length; i++) {
        for (var j = i + 1; j < layout.tiles.length; j++) {
          final a = layout.tiles[i], b = layout.tiles[j];
          final overlap = a.x < b.x + b.w - 1e-9 &&
              b.x < a.x + a.w - 1e-9 &&
              a.y < b.y + b.h - 1e-9 &&
              b.y < a.y + a.h - 1e-9;
          expect(overlap, isFalse, reason: '$reason : cases $i et $j se recouvrent');
        }
      }
    }

    test('pavage exact quel que soit le nombre de photos et de vedettes', () {
      for (var n = 5; n <= posterMaxPhotos; n++) {
        for (final featured in [
          <int>{},
          {0},
          {0, 1},
          {1, n - 1},
          {0, 2, 4},
          {for (var i = 0; i < n; i++) i},
        ]) {
          final layout = buildPosterLayout(n, featured);
          expect(layout.tiles.length, n, reason: 'n=$n, vedettes=$featured');
          expectExactTiling(layout, reason: 'n=$n, vedettes=$featured');
        }
      }
    });

    test('une vedette est nettement plus grande que les autres cases', () {
      for (final n in [5, 7, 12, 20, 40]) {
        final layout = buildPosterLayout(n, {0});
        final hero = layout.tiles[0];
        final others = [for (var i = 1; i < n; i++) layout.tiles[i]];
        final biggestOther =
            others.map((t) => t.w * t.h).reduce((a, b) => a > b ? a : b);
        expect(hero.w * hero.h, greaterThan(biggestOther), reason: 'n=$n');
        expect(hero.role, TileRole.large, reason: 'n=$n');
      }
    });

    test('plusieurs vedettes : toutes agrandies, ordre des photos préservé', () {
      final layout = buildPosterLayout(10, {2, 5});
      expect(layout.templateName, 'mosaicFeatured');
      for (final i in [2, 5]) {
        expect(layout.tiles[i].role, TileRole.large);
      }
      for (final i in [0, 1, 3, 4, 6, 7, 8, 9]) {
        expect(layout.tiles[i].role, TileRole.small);
      }
    });

    test('tout mettre en avant = grille égale (comme rien mettre en avant)', () {
      final all = buildPosterLayout(8, {for (var i = 0; i < 8; i++) i});
      final none = buildPosterLayout(8, {});
      for (var i = 0; i < 8; i++) {
        expect(all.tiles[i].w, closeTo(none.tiles[i].w, 1e-9));
        expect(all.tiles[i].h, closeTo(none.tiles[i].h, 1e-9));
      }
    });
  });

  group('PosterFormatRules', () {
    test('une photo plein cadre : A4 suffit', () {
      expect(PosterFormatRules.minSizeFor(buildPosterLayout(1, {})), 'A4');
    });

    test('le format minimum ne descend jamais quand on ajoute des photos', () {
      var previous = 0;
      for (var n = 1; n <= posterMaxPhotos; n++) {
        final index = PosterPricing.sizes
            .indexOf(PosterFormatRules.minSizeFor(buildPosterLayout(n, {})));
        expect(index, greaterThanOrEqualTo(previous), reason: 'n=$n');
        previous = index;
      }
    });

    test('beaucoup de photos → grand format imposé', () {
      expect(PosterFormatRules.minSizeFor(buildPosterLayout(9, {})), 'A3');
      expect(PosterFormatRules.minSizeFor(buildPosterLayout(16, {})), 'A2');
      expect(PosterFormatRules.minSizeFor(buildPosterLayout(posterMaxPhotos, {})), 'A0');
    });

    test('au format minimum, aucune photo ne descend sous 8 cm', () {
      for (var n = 1; n <= posterMaxPhotos; n++) {
        final layout = buildPosterLayout(n, n > 1 ? {0} : {});
        final size = PosterFormatRules.minSizeFor(layout);
        final mm = PosterFormatRules.smallestTileMm(layout, size);
        expect(mm, isNotNull, reason: 'n=$n');
        expect(mm, greaterThanOrEqualTo(PosterFormatRules.minTileMm - 0.1),
            reason: 'n=$n → $size');
      }
    });

    test('formats sélectionnables = le minimum et tout ce qui est au-dessus', () {
      final layout = buildPosterLayout(16, {});
      expect(PosterFormatRules.allowedSizes(layout), ['A2', 'A1', 'A0']);
      expect(PosterFormatRules.isTooSmall(layout, 'A4'), isTrue);
      expect(PosterFormatRules.isTooSmall(layout, 'A3'), isTrue);
      expect(PosterFormatRules.isTooSmall(layout, 'A2'), isFalse);
      expect(PosterFormatRules.isTooSmall(layout, 'A0'), isFalse);
    });

    test('collage paysage : A0 (absent du catalogue paysage) jamais proposé', () {
      final duo = buildPosterLayout(2, {0});
      expect(duo.orientation, PosterOrientation.landscape);
      expect(PosterFormatRules.allowedSizes(duo), isNot(contains('A0')));
      expect(PosterFormatRules.smallestTileMm(duo, 'A0'), isNull);
    });

    test('mettre une photo en avant rétrécit les autres, donc peut imposer '
        'un format plus grand', () {
      for (var n = 5; n <= posterMaxPhotos; n++) {
        final none = PosterPricing.sizes
            .indexOf(PosterFormatRules.minSizeFor(buildPosterLayout(n, {})));
        final one = PosterPricing.sizes
            .indexOf(PosterFormatRules.minSizeFor(buildPosterLayout(n, {0})));
        expect(one, greaterThanOrEqualTo(none), reason: 'n=$n');
      }
    });
  });
}
