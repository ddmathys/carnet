import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:bloom/core/models/book_draft.dart';

/// Commentaires posés sur les photos d'un livre : le rendu à l'écran
/// (PhotoEditScreen) et le rendu imprimé (BookPdfService) lisent les MÊMES
/// valeurs sur ce modèle. Un écart ici veut dire « ce que je place n'est pas
/// ce qui s'imprime » — d'où ces tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BookPhotoText', () {
    test('police et taille font l\'aller-retour Firestore', () {
      const t = BookPhotoText(
        text: 'Premier bain de mer',
        color: '#C4714B',
        font: BookPhotoText.fontScript,
        scale: 1.6,
        x: 0.25,
        y: 0.4,
      );
      final back = BookPhotoText.fromMap(t.toMap('photo-1'));
      expect(back.text, t.text);
      expect(back.color, t.color);
      expect(back.font, BookPhotoText.fontScript);
      expect(back.scale, closeTo(1.6, 0.0001));
      expect(back.x, closeTo(0.25, 0.0001));
      expect(back.y, closeTo(0.4, 0.0001));
    });

    test('un texte d\'avant les polices reste lisible, en serif à taille 1',
        () {
      final old = BookPhotoText.fromMap({
        'text': 'Vieux texte',
        'color': '#FFFFFF',
        'position': 'top',
        'background': true,
      });
      expect(old.font, BookPhotoText.fontSerif);
      expect(old.scale, 1);
      expect(old.position, 'top');
    });

    test('une police ou une taille aberrante est ramenée dans les bornes', () {
      final t = BookPhotoText.fromMap({
        'text': 'x',
        'font': 'comic-sans',
        'scale': 12,
      });
      expect(t.font, BookPhotoText.fontSerif);
      expect(t.scale, BookPhotoText.maxScale);
      expect(BookPhotoText.normalizeScale(0.1), BookPhotoText.minScale);
      expect(BookPhotoText.normalizeScale(null), 1);
    });

    test('changer de police ne change pas la taille apparente', () {
      // Caveat écrit bien plus petit que Fraunces à taille de police égale :
      // sans cette correction, passer en manuscrit « rapetissait » le texte.
      expect(BookPhotoText.metricOf(BookPhotoText.fontScript),
          greaterThan(BookPhotoText.metricOf(BookPhotoText.fontSerif)));
      const serif = BookPhotoText(text: 'a', font: BookPhotoText.fontSerif);
      const script = BookPhotoText(text: 'a', font: BookPhotoText.fontScript);
      expect(script.sizeFactor, greaterThan(serif.sizeFactor));
    });

    test('la taille choisie multiplie bien la taille de référence', () {
      const small = BookPhotoText(text: 'a', scale: 0.7);
      const big = BookPhotoText(text: 'a', scale: 2.2);
      expect(small.sizeFactor, closeTo(0.7, 0.0001));
      expect(big.sizeFactor, closeTo(2.2, 0.0001));
      // Les marges de l'encadré suivent, mais moins vite que le texte.
      expect(big.padFactor, lessThan(big.sizeFactor));
      expect(big.padFactor, greaterThan(1));
    });
  });

  group('Lignes qui tiennent dans la case', () {
    // Case demi-page A4 ≈ 595 × 421 pt, zone de sécurité de 10 mm de chaque
    // côté → ~364 pt de hauteur utile.
    const availablePt = 364.0;
    const baseFontSize = 14.0;
    const basePadV = 6.0;

    int lines(BookPhotoText t, [double available = availablePt]) =>
        t.lineCapacity(
            availableHeight: available,
            baseFontSize: baseFontSize,
            basePadV: basePadV);

    test('en taille normale, les 6 lignes sont permises', () {
      expect(lines(const BookPhotoText(text: 'a')), BookPhotoText.maxLines);
    });

    test('plus le texte est gros, moins de lignes tiennent', () {
      final normal = lines(const BookPhotoText(text: 'a'));
      final grand = lines(const BookPhotoText(text: 'a', scale: 2.2));
      expect(grand, lessThanOrEqualTo(normal));
    });

    test('une case minuscule laisse au moins une ligne', () {
      expect(lines(const BookPhotoText(text: 'a', scale: 2.2), 20), 1);
      expect(lines(const BookPhotoText(text: 'a'), 0), 1);
    });

    test('un quart de page en très grand ne peut pas déborder', () {
      // Quart de page ≈ 198 pt utiles ; à 2.2× en manuscrit, une ligne fait
      // ~44 pt → quatre lignes au plus, jamais six.
      final t = const BookPhotoText(
          text: 'a', scale: 2.2, font: BookPhotoText.fontScript);
      final n = lines(t, 198);
      expect(n, greaterThanOrEqualTo(1));
      expect(
          n * (baseFontSize * t.sizeFactor * 1.25 + 2), lessThanOrEqualTo(198));
    });
  });

  group('Polices des commentaires', () {
    test('chaque police a un .ttf chargeable par le PDF', () async {
      for (final font in BookPhotoText.fonts) {
        final asset = BookPhotoText.assetOf(font);
        final data = await rootBundle.load(asset);
        expect(data.lengthInBytes, greaterThan(1000),
            reason: '$asset introuvable ou vide');
        // Même parsing que BookPdfService : une police illisible ici ferait
        // échouer la génération du livre, pas seulement l'affichage.
        expect(() => pw.Font.ttf(data), returnsNormally);
      }
    });

    test('la famille Flutter et le .ttf du PDF désignent le même fichier', () {
      // L'éditeur applique la famille, le PDF charge le fichier : si les deux
      // divergent, l'aperçu mentirait sur ce qui sera imprimé.
      const expected = {
        BookPhotoText.fontSerif: ('Fraunces', 'assets/fonts/Fraunces.ttf'),
        BookPhotoText.fontSans: ('Outfit', 'assets/fonts/Outfit.ttf'),
        BookPhotoText.fontScript: ('Caveat', 'assets/fonts/Caveat.ttf'),
      };
      for (final e in expected.entries) {
        expect(BookPhotoText.familyOf(e.key), e.value.$1);
        expect(BookPhotoText.assetOf(e.key), e.value.$2);
        expect(e.value.$2.contains(e.value.$1), isTrue);
      }
    });
  });
}
