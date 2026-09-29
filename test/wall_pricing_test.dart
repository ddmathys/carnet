import 'package:bloom/core/services/poster_pricing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Tableaux muraux (toile / encadré)', () {
    test('tailles par matière et SKU Prodigi', () {
      expect(PosterPricing.sizesFor('hanger'), PosterPricing.sizes);
      expect(PosterPricing.sizesFor('canvas'),
          ['CAN-12X16', 'CAN-16X20', 'CAN-24X32', 'CAN-28X40']);
      for (final size in [
        ...PosterPricing.sizesFor('canvas'),
        ...PosterPricing.sizesFor('framed'),
      ]) {
        for (final o in ['portrait', 'landscape']) {
          expect(PosterPricing.entryFor(size, o)?.sku, 'GLOBAL-$size');
          expect(PosterPricing.price(size, o), greaterThan(0));
        }
      }
    });

    test('matière, libellés et orientation', () {
      expect(PosterPricing.materialOf('A3'), 'hanger');
      expect(PosterPricing.materialOf('CAN-16X20'), 'canvas');
      expect(PosterPricing.materialOf('CFP-16X20'), 'framed');
      expect(PosterPricing.label('CAN-16X20'), 'Toile 40 × 50 cm');
      expect(PosterPricing.label('CFP-12X16'), 'Tirage encadré 30 × 40 cm');
      expect(PosterPricing.label('A3'), 'Tirage A3');
      expect(PosterPricing.colorsFor('canvas'), isEmpty);
      final land = PosterPricing.entryFor('CAN-16X20', 'landscape')!;
      expect(land.printAreaPxW, greaterThan(land.printAreaPxH));
      final mm = PosterPricing.mmFor('CFP-16X20', 'portrait')!;
      expect(mm.wMm, closeTo(406.4, 0.01));
      expect(PosterPricing.entryFor('CAN-99X99', 'portrait'), isNull);
    });
  });
}
