import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua/app.dart';
import 'package:lingua/core/storage/key_value_store.dart';
import 'package:lingua/core/store/store_scope.dart';
import 'package:lingua/core/store/vocab_store.dart';

void main() {
  Future<VocabStore> pumpApp(WidgetTester tester, {String? language}) async {
    final VocabStore store = VocabStore(MemoryKeyValueStore());
    await store.load();
    if (language != null) await store.addLanguage(language);
    await tester.pumpWidget(
      StoreScope(store: store, child: const LinguaApp()),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('premier lancement : on choisit sa langue', (
    WidgetTester tester,
  ) async {
    final VocabStore store = await pumpApp(tester);

    expect(find.text('Bienvenue'), findsOneWidget);

    await tester.tap(find.text('Espagnol'));
    await tester.pumpAndSettle();

    expect(store.activeLanguage, 'es');
    expect(find.text('Ton carnet est vide'), findsOneWidget);
  });

  testWidgets('ajouter une entrée la fait apparaître dans le carnet', (
    WidgetTester tester,
  ) async {
    final VocabStore store = await pumpApp(tester, language: 'es');

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Ajouter'));
    await tester.pumpAndSettle();

    final Finder fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'el mercado');
    await tester.enterText(fields.at(1), 'le marché');
    await tester.enterText(fields.at(2), 'Voy al mercado los sábados.');
    await tester.enterText(fields.at(3), 'Voyage');

    await tester.tap(find.widgetWithText(FilledButton, 'Enregistrer'));
    await tester.pumpAndSettle();

    expect(store.allEntries, hasLength(1));
    expect(find.text('el mercado'), findsOneWidget);
    expect(find.text('le marché'), findsOneWidget);
    expect(find.text('« Voy al mercado los sábados. »'), findsOneWidget);
    // Le thème devient un filtre disponible en haut du carnet.
    expect(find.text('Voyage'), findsNWidgets(2));
  });

  testWidgets('le mot est requis', (WidgetTester tester) async {
    await pumpApp(tester, language: 'es');

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Ajouter'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Enregistrer'));
    await tester.pumpAndSettle();

    expect(find.text('Il faut au moins le mot ou la phrase.'), findsOneWidget);
    // On reste sur le formulaire.
    expect(find.text('Nouvelle entrée'), findsOneWidget);
  });

  testWidgets('la recherche filtre la liste', (WidgetTester tester) async {
    final VocabStore store = await pumpApp(tester, language: 'es');
    await store.addEntry(
      languageCode: 'es',
      term: 'el mercado',
      translation: 'le marché',
    );
    await store.addEntry(
      languageCode: 'es',
      term: 'el pan',
      translation: 'le pain',
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'pan');
    await tester.pumpAndSettle();

    expect(find.text('el pan'), findsOneWidget);
    expect(find.text('el mercado'), findsNothing);
  });
}
