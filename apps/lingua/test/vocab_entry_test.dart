import 'package:flutter_test/flutter_test.dart';
import 'package:lingua/core/models/vocab_entry.dart';

void main() {
  VocabEntry entry({
    String term = 'el mercado',
    String translation = 'le marché',
    String context = 'Voy al mercado los sábados.',
    String category = 'Voyage',
    bool isLearned = false,
  }) {
    return VocabEntry(
      id: 'id-1',
      languageCode: 'es',
      term: term,
      translation: translation,
      context: context,
      category: category,
      createdAt: DateTime.utc(2026, 3, 14, 9, 30),
      isLearned: isLearned,
    );
  }

  group('sérialisation', () {
    test('aller-retour JSON sans perte', () {
      final VocabEntry original = entry(isLearned: true);
      final VocabEntry restored = VocabEntry.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.languageCode, original.languageCode);
      expect(restored.term, original.term);
      expect(restored.translation, original.translation);
      expect(restored.context, original.context);
      expect(restored.category, original.category);
      expect(restored.createdAt, original.createdAt);
      expect(restored.isLearned, isTrue);
    });

    test('champs manquants ou mal typés : valeurs par défaut, pas de crash',
        () {
      final VocabEntry restored = VocabEntry.fromJson(<String, dynamic>{
        'id': 'x',
        'term': 'die Wolke',
        'translation': 42,
      });

      expect(restored.term, 'die Wolke');
      expect(restored.translation, '');
      expect(restored.context, '');
      expect(restored.category, '');
      expect(restored.isLearned, isFalse);
      expect(restored.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
    });
  });

  group('recherche', () {
    test('une requête vide accepte tout', () {
      expect(entry().matches(''), isTrue);
      expect(entry().matches('   '), isTrue);
    });

    test('cherche aussi dans le contexte et le thème', () {
      expect(entry().matches('sábados'), isTrue);
      expect(entry().matches('voyage'), isTrue);
      expect(entry().matches('boulot'), isFalse);
    });

    test('accents et casse ignorés', () {
      expect(entry().matches('MARCHE'), isTrue);
      expect(entry().matches('sabados'), isTrue);
      expect(foldForSearch('Café  '), 'cafe');
    });
  });

  test('copyWith garde id et date de création', () {
    final VocabEntry original = entry();
    final VocabEntry updated =
        original.copyWith(term: 'la plaza', isLearned: true);

    expect(updated.id, original.id);
    expect(updated.createdAt, original.createdAt);
    expect(updated.term, 'la plaza');
    expect(updated.translation, original.translation);
    expect(updated.isLearned, isTrue);
  });
}
