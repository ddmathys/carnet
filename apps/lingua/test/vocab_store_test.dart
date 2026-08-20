import 'package:flutter_test/flutter_test.dart';
import 'package:lingua/core/models/vocab_entry.dart';
import 'package:lingua/core/storage/key_value_store.dart';
import 'package:lingua/core/store/vocab_store.dart';

void main() {
  late MemoryKeyValueStore storage;
  late VocabStore store;

  setUp(() async {
    storage = MemoryKeyValueStore();
    store = VocabStore(storage);
    await store.load();
  });

  test('démarre vide, sans langue active', () {
    expect(store.isLoaded, isTrue);
    expect(store.languages, isEmpty);
    expect(store.activeLanguage, isNull);
  });

  test('ajouter une langue la rend active', () async {
    await store.addLanguage('es');
    await store.addLanguage('de');

    expect(store.languages, <String>['es', 'de']);
    expect(store.activeLanguage, 'de');

    // Une langue déjà présente n'est pas dupliquée.
    await store.addLanguage('es');
    expect(store.languages, <String>['es', 'de']);
    expect(store.activeLanguage, 'es');
  });

  test('les entrées survivent à un redémarrage', () async {
    await store.addLanguage('es');
    await store.addEntry(
      languageCode: 'es',
      term: '  el mercado  ',
      translation: 'le marché',
      context: 'Voy al mercado.',
      category: '  Voyage ',
    );

    // Nouveau store branché sur le même stockage = relance de l'app.
    final VocabStore reloaded = VocabStore(storage);
    await reloaded.load();

    expect(reloaded.languages, <String>['es']);
    expect(reloaded.activeLanguage, 'es');
    expect(reloaded.allEntries, hasLength(1));

    final VocabEntry entry = reloaded.allEntries.single;
    expect(entry.term, 'el mercado', reason: 'les espaces sont rognés');
    expect(entry.category, 'Voyage');
    expect(entry.context, 'Voy al mercado.');
  });

  test('un carnet illisible ne bloque pas le démarrage', () async {
    final VocabStore broken = VocabStore(
      MemoryKeyValueStore(<String, String>{
        VocabStore.entriesKey: 'ceci n\'est pas du JSON',
        VocabStore.settingsKey: '{{{',
      }),
    );
    await broken.load();

    expect(broken.isLoaded, isTrue);
    expect(broken.allEntries, isEmpty);
    expect(broken.languages, isEmpty);
  });

  test('supprimer une langue emporte ses entrées', () async {
    await store.addLanguage('es');
    await store.addEntry(languageCode: 'es', term: 'el mercado');
    await store.addLanguage('de');
    await store.addEntry(languageCode: 'de', term: 'die Wolke');

    await store.removeLanguage('de');

    expect(store.languages, <String>['es']);
    expect(store.activeLanguage, 'es');
    expect(store.allEntries.map((VocabEntry e) => e.term), <String>['el mercado']);
  });

  test('supprimer puis annuler remet l\'entrée', () async {
    await store.addLanguage('es');
    final VocabEntry entry =
        await store.addEntry(languageCode: 'es', term: 'el mercado');

    await store.deleteEntry(entry.id);
    expect(store.allEntries, isEmpty);

    await store.restoreEntry(entry);
    expect(store.allEntries.single.id, entry.id);

    // Restaurer deux fois ne duplique pas.
    await store.restoreEntry(entry);
    expect(store.allEntries, hasLength(1));
  });

  test('thèmes triés, sans les non classées', () async {
    await store.addLanguage('es');
    await store.addEntry(languageCode: 'es', term: 'a', category: 'Voyage');
    await store.addEntry(languageCode: 'es', term: 'b', category: 'Épicerie');
    await store.addEntry(languageCode: 'es', term: 'c');
    await store.addEntry(languageCode: 'de', term: 'd', category: 'Boulot');

    expect(store.categoriesFor('es'), <String>['Épicerie', 'Voyage']);
    expect(store.hasUncategorized('es'), isTrue);
    expect(store.hasUncategorized('de'), isFalse);
    expect(store.countFor('es'), 3);
  });

  group('filtrage', () {
    final List<VocabEntry> source = <VocabEntry>[
      VocabEntry(
        id: '1',
        languageCode: 'es',
        term: 'el mercado',
        translation: 'le marché',
        context: 'Voy al mercado los sábados.',
        category: 'Voyage',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
      VocabEntry(
        id: '2',
        languageCode: 'es',
        term: 'la reunión',
        translation: 'la réunion',
        context: '',
        category: 'Boulot',
        createdAt: DateTime.utc(2026, 2, 1),
        isLearned: true,
      ),
      VocabEntry(
        id: '3',
        languageCode: 'es',
        term: 'el pan',
        translation: 'le pain',
        context: '',
        category: '',
        createdAt: DateTime.utc(2026, 3, 1),
      ),
      VocabEntry(
        id: '4',
        languageCode: 'de',
        term: 'die Wolke',
        translation: 'le nuage',
        context: '',
        category: 'Voyage',
        createdAt: DateTime.utc(2026, 4, 1),
      ),
    ];

    List<String> ids(List<VocabEntry> entries) =>
        entries.map((VocabEntry e) => e.id).toList();

    test('une seule langue, de la plus récente à la plus ancienne', () {
      expect(
        ids(VocabStore.filterEntries(source, languageCode: 'es')),
        <String>['3', '2', '1'],
      );
    });

    test('category null = tous, \'\' = non classées', () {
      expect(
        ids(VocabStore.filterEntries(source,
            languageCode: 'es', category: 'Voyage')),
        <String>['1'],
      );
      expect(
        ids(VocabStore.filterEntries(source, languageCode: 'es', category: '')),
        <String>['3'],
      );
    });

    test('la recherche va chercher dans le contexte', () {
      expect(
        ids(VocabStore.filterEntries(source,
            languageCode: 'es', query: 'sabados')),
        <String>['1'],
      );
    });

    test('masquer les acquis', () {
      expect(
        ids(VocabStore.filterEntries(source,
            languageCode: 'es', hideLearned: true)),
        <String>['3', '1'],
      );
    });

    test('les filtres se combinent', () {
      expect(
        VocabStore.filterEntries(source,
            languageCode: 'es', category: 'Boulot', hideLearned: true),
        isEmpty,
      );
    });
  });
}
