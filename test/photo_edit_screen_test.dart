import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bloom/core/models/book_draft.dart';
import 'package:bloom/core/services/book_pdf_service.dart';
import 'package:bloom/features/books/photo_edit_screen.dart';

/// Écran « cette photo » : on vérifie ce qu'il RENVOIE (c'est ce qui part dans
/// le brouillon puis dans le PDF), pas son apparence.
void main() {
  // PNG 1 × 1 valide — suffit à Image.memory, on ne regarde pas le pixel.
  final png = Uint8List.fromList(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=='));

  // Case demi-page A4 (cf. BookPdfService._cellRects).
  final slot = BookPhotoSlot(
    pageIndex: 1,
    memoryId: 'm1',
    rawId: 'memories/m1/photo.jpg',
    bytes: png,
    isPortrait: false,
    widthPt: 595,
    heightPt: 421,
    left: 0,
    top: 0,
    width: 1,
    height: 0.5,
  );

  testWidgets('écrire un commentaire renvoie le texte, la police et la taille',
      (tester) async {
    PhotoEditResult? captured;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await PhotoEditScreen.open(
                  context,
                  slot: slot,
                  defaultColor: '#2D2416',
                );
              },
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Premier bain de mer');
    await tester.pump();
    // Police manuscrite
    await tester
        .tap(find.text(BookPhotoText.labelOf(BookPhotoText.fontScript)));
    await tester.pump();
    // Taille au maximum du curseur
    await tester.drag(find.byType(Slider), const Offset(500, 0));
    await tester.pump();

    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    final saved = captured as PhotoTextSaved;
    final text = saved.text!;
    expect(text.text, 'Premier bain de mer');
    expect(text.font, BookPhotoText.fontScript);
    expect(text.scale, BookPhotoText.maxScale);
    expect(text.x, BookPhotoText.defaultX);
    expect(text.y, BookPhotoText.defaultY);
  });

  testWidgets('déplacer l\'encadré change sa position, sans sortir de la photo',
      (tester) async {
    PhotoEditResult? captured;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await PhotoEditScreen.open(
                  context,
                  slot: slot,
                  defaultColor: '#2D2416',
                  initial: const BookPhotoText(text: 'Déjà écrit'),
                );
              },
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();

    // Vers le haut et la gauche, bien au-delà de la photo : la position doit
    // être bornée, jamais hors case (le texte serait rogné à l'impression).
    // Le même texte apparaît dans la zone de saisie : on vise l'encadré
    // posé sur la photo, premier dans l'arbre.
    await tester.drag(
        find.text('Déjà écrit').first, const Offset(-4000, -4000));
    await tester.pump();
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    final text = (captured as PhotoTextSaved).text!;
    expect(text.x, 0.0);
    expect(text.y, 0.0);
  });

  testWidgets('vider le texte d\'un commentaire existant le supprime',
      (tester) async {
    PhotoEditResult? captured;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await PhotoEditScreen.open(
                  context,
                  slot: slot,
                  defaultColor: '#2D2416',
                  initial: const BookPhotoText(text: 'À effacer'),
                );
              },
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    await tester.tap(find.text('Supprimer le commentaire'));
    await tester.pumpAndSettle();

    expect((captured as PhotoTextSaved).text, isNull);
  });
}
