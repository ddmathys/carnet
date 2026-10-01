import 'package:flutter_test/flutter_test.dart';
import 'package:bloom/core/services/book_pricing.dart';
import 'package:bloom/core/services/poster_pricing.dart';
import 'package:bloom/core/services/puzzle_pricing.dart';

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
    test('le puzzle le moins cher coûte 34', () {
      expect(PuzzlePricing.minPrice, 34.0);
      expect(PuzzlePricing.price('30'), 34.0);
    });

    test('un puzzle supplémentaire coûte moins cher que le premier', () {
      final first = PuzzlePricing.price('30')!;
      final extra = PuzzlePricing.priceAdditional('30')!;
      expect(extra, lessThan(first));
      expect(extra, greaterThanOrEqualTo(PuzzlePricing.marginFloor));
    });

    test('plus de pièces, plus cher', () {
      expect(PuzzlePricing.price('1000')!,
          greaterThan(PuzzlePricing.price('30')!));
    });
  });
}
