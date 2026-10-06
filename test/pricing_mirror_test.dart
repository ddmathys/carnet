import 'package:flutter_test/flutter_test.dart';
import 'package:bloom/core/services/book_pricing.dart';
import 'package:bloom/core/services/poster_pricing.dart';
import 'package:bloom/core/services/puzzle_pricing.dart';
import 'package:bloom/core/services/puzzle_quality_service.dart';

/// Les trois tables de prix de l'app sont des MIROIRS de `backend/lib/*.ts`.
/// Rien ne les reliait : le backend était testé, l'app pas du tout, et les
/// deux ont déjà divergé (écrêtage du nombre de pages, audit du 01.10.26).
/// Ces tests figent les valeurs que le serveur facture réellement — ils
/// doivent échouer dès que l'un des deux côtés bouge sans l'autre.
void main() {
  group('BookPricing', () {
    test('le livre le moins cher coûte 37.50, pas 29', () {
      expect(BookPricing.price(coverType: 'soft', pages: 20), 37.5);
      expect(BookPricing.minPrice, 37.5);
    });

    test('les minimums de pages sont comblés, pas facturés en dessous', () {
      // 10 pages demandées, 20 facturées (minimum produit du softcover).
      expect(BookPricing.price(coverType: 'soft', pages: 10),
          BookPricing.price(coverType: 'soft', pages: 20));
    });

    test('le nombre de pages est écrêté comme côté serveur', () {
      // Borne layflat = 122 pages : au-delà, même prix (le serveur refuse la
      // commande, mais l'affichage ne doit jamais dépasser ce qu'il facture).
      expect(BookPricing.price(coverType: 'layflat', pages: 150),
          BookPricing.price(coverType: 'layflat', pages: 122));
    });

    test('un livre supplémentaire coûte moins cher (port déduit)', () {
      final first = BookPricing.price(coverType: 'soft', pages: 40);
      final extra = BookPricing.priceAdditional(coverType: 'soft', pages: 40);
      expect(extra, lessThan(first));
      expect(extra, greaterThanOrEqualTo(BookPricing.marginFloor));
    });

    test('le layflat reste plus cher que le soft à pagination égale', () {
      expect(BookPricing.price(coverType: 'layflat', pages: 40),
          greaterThan(BookPricing.price(coverType: 'soft', pages: 40)));
    });
  });

  group('PosterPricing', () {
    test('le tirage le moins cher du catalogue public coûte 31', () {
      expect(PosterPricing.minPrice, 31.0);
      expect(PosterPricing.price('A4', 'portrait'), 31.0);
    });

    test('un tirage supplémentaire coûte moins cher que le premier', () {
      final first = PosterPricing.price('A4', 'portrait')!;
      final extra = PosterPricing.priceAdditional('A4', 'portrait')!;
      expect(extra, lessThan(first));
      expect(first + extra, lessThan(first * 2));
      expect(extra, greaterThanOrEqualTo(PosterPricing.marginFloor));
    });

    test('A0 paysage n’existe pas, ni au prix normal ni au prix groupé', () {
      expect(PosterPricing.price('A0', 'landscape'), isNull);
      expect(PosterPricing.priceAdditional('A0', 'landscape'), isNull);
    });
  });

  group('PuzzlePricing', () {
    // Ces trois valeurs DOIVENT rester identiques à celles asséntées dans
    // backend/lib/pricing.test.ts — c'est tout l'intérêt du miroir : si l'un
    // des deux fichiers de tarif dérive, un des deux jeux de tests casse.
    test('tarif premium : 52 / 59 / 68', () {
      expect(PuzzlePricing.price('252'), 52.0);
      expect(PuzzlePricing.price('500'), 59.0);
      expect(PuzzlePricing.price('1000'), 68.0);
      expect(PuzzlePricing.minPrice, 52.0);
    });

    test('le 1000 pièces est au-dessus du prix livré d\'ifolor (55.90)', () {
      expect(PuzzlePricing.price('1000')!, greaterThan(55.90));
    });

    test('les tailles 30 et 110 ont été retirées du catalogue', () {
      expect(PuzzlePricing.sizes, ['252', '500', '1000']);
      expect(PuzzlePricing.price('30'), isNull);
      expect(PuzzlePricing.price('110'), isNull);
    });

    test('un puzzle supplémentaire coûte moins cher que le premier', () {
      final first = PuzzlePricing.price('252')!;
      final extra = PuzzlePricing.priceAdditional('252')!;
      expect(extra, lessThan(first));
      expect(extra, greaterThanOrEqualTo(PuzzlePricing.marginFloor));
    });

    test('plus de pièces, plus cher', () {
      expect(PuzzlePricing.price('1000')!,
          greaterThan(PuzzlePricing.price('252')!));
    });
  });

  // Contrôle qualité ajouté le 06.10.26 : sans lui, l'app laissait commander
  // un 1000 pièces (zone d'impression 9035 × 6200) depuis une photo stockée à
  // 2048 px, soit ~68 DPI effectifs sur un objet physique payé.
  group('PuzzleQualityService', () {
    test('une photo stockée à 2048 px bloque les grandes tailles', () {
      const dims = (w: 2048, h: 1536);
      final all = PuzzleQualityService.evaluateAll(dims);
      expect(all['1000']!.verdict, PuzzleQualityVerdict.disabled);
      expect(all['500']!.verdict, PuzzleQualityVerdict.disabled);
      // 252 pièces : ~139 DPI, sous les 150 du seuil « limite » → bloqué too.
      expect(all['252']!.verdict, PuzzleQualityVerdict.disabled);
      expect(PuzzleQualityService.largestOrderable(dims), isNull);
    });

    test('une photo pleine résolution ouvre les grandes tailles', () {
      // 9035 px de large = exactement la zone d'impression du 1000 pièces.
      const dims = (w: 9035, h: 6200);
      final all = PuzzleQualityService.evaluateAll(dims);
      expect(all['1000']!.verdict, PuzzleQualityVerdict.ok);
      expect(PuzzleQualityService.largestOrderable(dims), '1000');
    });

    test('le DPI annoncé correspond au rapport de pixels', () {
      final q = PuzzleQualityService.evaluate(
          size: '1000', photoDims: (w: 2048, h: 1536));
      // 300 × 2048 / 9035 ≈ 68
      expect(q.achievableDpi!.round(), 68);
      expect(PuzzleQualityService.dpiLabel(q), '~68 DPI');
    });

    test('dimensions illisibles : qualité limite, jamais un blocage', () {
      final all = PuzzleQualityService.evaluateAll(null);
      for (final size in PuzzlePricing.sizes) {
        expect(all[size]!.verdict, PuzzleQualityVerdict.limited);
        expect(all[size]!.isOrderable, isTrue);
      }
    });

    test('une taille hors catalogue est désactivée', () {
      final q = PuzzleQualityService.evaluate(
          size: '30', photoDims: (w: 4000, h: 3000));
      expect(q.verdict, PuzzleQualityVerdict.disabled);
    });
  });

  // Le QR du couvercle (06.10.26) ne survit que si le PDF composé a EXACTEMENT
  // les proportions de la zone d'impression `lid` : `sizing` est défini au
  // niveau de l'article chez Prodigi, donc le couvercle subit le même
  // `fillPrintArea` que le puzzle, et tout écart de ratio rogne — en coupant
  // le QR. Dimensions relevées dans la fiche produit publique de Prodigi.
  group("Zone d'impression du couvercle", () {
    test('les dimensions du couvercle viennent de la fiche Prodigi', () {
      expect(PuzzlePricing.entryFor('252')!.lidPrintAreaPxW, 869);
      expect(PuzzlePricing.entryFor('252')!.lidPrintAreaPxH, 674);
      // 500 et 1000 partagent la même boîte (202 x 167 x 63 mm).
      expect(PuzzlePricing.entryFor('500')!.lidPrintAreaPxW, 1724);
      expect(PuzzlePricing.entryFor('1000')!.lidPrintAreaPxW, 1724);
      expect(PuzzlePricing.entryFor('500')!.lidPrintAreaPxH, 1169);
      expect(PuzzlePricing.entryFor('1000')!.lidPrintAreaPxH, 1169);
    });

    test('le ratio du couvercle est exploitable et jamais nul', () {
      for (final size in PuzzlePricing.sizes) {
        final e = PuzzlePricing.entryFor(size)!;
        expect(e.lidAspect, greaterThan(1.0), reason: '$size : couvercle paysage attendu');
        expect(e.lidAspect, closeTo(e.lidPrintAreaPxW / e.lidPrintAreaPxH, 1e-9));
      }
    });

    test('la zone du puzzle correspond bien a 300 DPI sur la taille assemblee', () {
      // 765 mm = 30.12 pouces ; 9035 px / 30.12 = 300 DPI. Vérifie que les
      // deux sources (zone d'impression et taille assemblée) sont coherentes,
      // donc que le calcul de DPI de PuzzleQualityService est bien calibre.
      for (final size in PuzzlePricing.sizes) {
        final e = PuzzlePricing.entryFor(size)!;
        final inches = e.assembledMmW / 25.4;
        expect(e.printAreaPxW / inches, closeTo(300, 6), reason: size);
      }
    });
  });
}
