import 'package:flutter_test/flutter_test.dart';
import 'package:bloom/core/models/poster_template.dart';
import 'package:bloom/core/services/poster_pricing.dart';
import 'package:bloom/core/services/poster_quality_service.dart';

void main() {
  group('buildPosterLayout', () {
    test('1 photo → single, plein cadre, portrait', () {
      final l = buildPosterLayout(1, {});
      expect(l.templateName, 'single');
      expect(l.tiles.length, 1);
      expect(l.tiles.first.w, 1);
      expect(l.tiles.first.h, 1);
      expect(l.orientation, PosterOrientation.portrait);
    });

    test('2 photos, 1 vedette → duoFeatured, paysage, 65/35', () {
      final l = buildPosterLayout(2, {0});
      expect(l.templateName, 'duoFeatured');
      expect(l.orientation, PosterOrientation.landscape);
      expect(l.tiles[0].w, closeTo(0.65, 1e-9));
      expect(l.tiles[1].w, closeTo(0.35, 1e-9));
    });

    test('2 photos, aucune vedette → duoEqual 50/50', () {
      final l = buildPosterLayout(2, {});
      expect(l.templateName, 'duoEqual');
      expect(l.tiles[0].w, closeTo(0.5, 1e-9));
      expect(l.tiles[1].w, closeTo(0.5, 1e-9));
    });

    test('4 photos, 0 vedette → quadGrid, 4 cases égales', () {
      final l = buildPosterLayout(4, {});
      expect(l.templateName, 'quadGrid');
      expect(l.tiles.length, 4);
      for (final t in l.tiles) {
        expect(t.w, closeTo(0.5, 1e-9));
        expect(t.h, closeTo(0.5, 1e-9));
      }
    });

    test('4 photos, 1 vedette → quadFeatured', () {
      final l = buildPosterLayout(4, {2});
      expect(l.templateName, 'quadFeatured');
      expect(l.tiles[2].w, closeTo(0.55, 1e-9));
    });

    test('5 et 6 photos → gridSmall, une case par photo', () {
      expect(buildPosterLayout(5, {}).tiles.length, 5);
      expect(buildPosterLayout(6, {}).tiles.length, 6);
      expect(buildPosterLayout(6, {}).templateName, 'gridSmall');
    });
  });

  group('PosterQualityService.evaluate', () {
    // A4 portrait : printAreaPx confirmé 2490×3510 (= 300 DPI).
    final layout = buildPosterLayout(1, {}); // single, tile plein cadre

    test('résolution exacte à 300 DPI → ok', () {
      final q = PosterQualityService.evaluate(
        size: 'A4',
        orientation: 'portrait',
        layout: layout,
        photoDims: [(w: 2490, h: 3510)],
      );
      expect(q.verdict, PosterQualityVerdict.ok);
      expect(q.achievableDpi, closeTo(300, 0.1));
    });

    test('résolution à la moitié (150 DPI) → limited (borne incluse)', () {
      final q = PosterQualityService.evaluate(
        size: 'A4',
        orientation: 'portrait',
        layout: layout,
        photoDims: [(w: 1245, h: 1755)],
      );
      expect(q.verdict, PosterQualityVerdict.limited);
      expect(q.achievableDpi, closeTo(150, 0.5));
    });

    test('résolution juste sous 150 DPI → disabled', () {
      final q = PosterQualityService.evaluate(
        size: 'A4',
        orientation: 'portrait',
        layout: layout,
        photoDims: [(w: 1200, h: 1690)],
      );
      expect(q.verdict, PosterQualityVerdict.disabled);
    });

    test('A0 paysage (absent du catalogue) → toujours disabled', () {
      final q = PosterQualityService.evaluate(
        size: 'A0',
        orientation: 'landscape',
        layout: layout,
        photoDims: [(w: 20000, h: 20000)],
      );
      expect(q.verdict, PosterQualityVerdict.disabled);
      expect(PosterPricing.entryFor('A0', 'landscape'), isNull);
    });

    test('collage : une petite photo suffit pour une grande taille', () {
      // 6 photos en grille égale : chaque case ne demande qu'1/9e (env.) de
      // la résolution plein cadre — une photo modeste doit débloquer l'A0
      // alors qu'elle ne le pourrait pas seule en plein cadre.
      final gridLayout = buildPosterLayout(6, {});
      final dims = List.generate(6, (_) => (w: 4000, h: 4000));
      final full = PosterQualityService.evaluate(
        size: 'A0',
        orientation: 'portrait',
        layout: buildPosterLayout(1, {}),
        photoDims: [(w: 4000, h: 4000)],
      );
      final grid = PosterQualityService.evaluate(
        size: 'A0',
        orientation: 'portrait',
        layout: gridLayout,
        photoDims: dims,
      );
      expect(full.verdict, PosterQualityVerdict.disabled);
      expect(grid.verdict, isNot(PosterQualityVerdict.disabled));
    });
  });
}
