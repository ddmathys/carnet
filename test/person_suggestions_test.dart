import 'package:flutter_test/flutter_test.dart';
import 'package:bloom/core/models/memory_model.dart';
import 'package:bloom/core/models/tag_model.dart';
import 'package:bloom/features/tags/person_suggestions.dart';

TagModel _person(String label, {DateTime? birthdate}) => TagModel(
      id: label.toLowerCase(),
      userId: 'u1',
      label: label,
      kind: birthdate != null ? 'enfant' : 'personne',
      birthdate: birthdate,
      createdAt: DateTime(2020, 1, 1),
    );

MemoryModel _memory({
  required String id,
  required DateTime date,
  List<String> people = const [],
  String? location,
  DateTime? createdAt,
}) =>
    MemoryModel(
      id: id,
      notebookId: 'nb',
      userId: 'u1',
      type: 'anecdote',
      date: date,
      location: location,
      rawContent: '',
      tagLabels: [...people, if (location != null) location],
      createdAt: createdAt ?? date,
    );

void main() {
  group('suggestPeople', () {
    test('ne propose rien sans historique', () {
      final out = suggestPeople(
        memories: const [],
        people: [_person('Léa')],
        alreadySelected: const {},
        date: DateTime(2026, 10, 6),
      );
      expect(out, isEmpty);
    });

    test('ne propose jamais une personne jamais taguée', () {
      final out = suggestPeople(
        memories: [
          _memory(id: 'm1', date: DateTime(2026, 1, 1), people: ['Léa']),
        ],
        people: [_person('Léa'), _person('Inconnue')],
        alreadySelected: const {},
        date: DateTime(2026, 10, 6),
      );
      expect(out.map((s) => s.tag.label), ['Léa']);
    });

    test('le lieu fait remonter celui qui y est toujours', () {
      final memories = [
        for (var i = 0; i < 6; i++)
          _memory(
            id: 'verbier$i',
            date: DateTime(2024, 2, i + 1),
            people: ['Papi'],
            location: 'Verbier',
          ),
        // Beaucoup plus de souvenirs avec Léa, mais jamais à Verbier : la
        // proportion au lieu doit l'emporter sur la fréquence globale.
        for (var i = 0; i < 20; i++)
          _memory(
            id: 'maison$i',
            date: DateTime(2025, 5, (i % 28) + 1),
            people: ['Léa'],
            location: 'Maison',
          ),
      ];
      final out = suggestPeople(
        memories: memories,
        people: [_person('Papi'), _person('Léa')],
        alreadySelected: const {},
        date: DateTime(2026, 10, 6),
        location: 'Verbier',
      );
      expect(out.first.tag.label, 'Papi');
      expect(out.first.reason, 'souvent à Verbier');
    });

    test('la proximité de date rattrape un voyage', () {
      final memories = [
        for (var i = 0; i < 5; i++)
          _memory(
            id: 'voyage$i',
            date: DateTime(2026, 7, i + 1),
            people: ['Mamie'],
          ),
        for (var i = 0; i < 5; i++)
          _memory(
            id: 'hiver$i',
            date: DateTime(2026, 1, i + 1),
            people: ['Léa'],
          ),
      ];
      final out = suggestPeople(
        memories: memories,
        people: [_person('Mamie'), _person('Léa')],
        alreadySelected: const {},
        date: DateTime(2026, 7, 10),
      );
      expect(out.first.tag.label, 'Mamie');
      expect(out.first.reason, 'à cette période');
    });

    test('une personne déjà posée sur le souvenir n’est pas reproposée', () {
      final memories = [
        for (var i = 0; i < 5; i++)
          _memory(id: 'm$i', date: DateTime(2026, 3, i + 1), people: ['Léa']),
      ];
      final out = suggestPeople(
        memories: memories,
        people: [_person('Léa')],
        alreadySelected: {'léa'},
        date: DateTime(2026, 3, 10),
      );
      expect(out, isEmpty);
    });

    test('un enfant né après le souvenir ne reçoit pas le coup de pouce', () {
      final memories = [
        for (var i = 0; i < 4; i++)
          _memory(id: 'a$i', date: DateTime(2026, 5, i + 1), people: ['Noé']),
        for (var i = 0; i < 4; i++)
          _memory(id: 'b$i', date: DateTime(2026, 5, i + 1), people: ['Papa']),
      ];
      final people = [
        _person('Noé', birthdate: DateTime(2027, 1, 1)),
        _person('Papa'),
      ];
      double scoreOf(List<PersonSuggestion> l, String label) =>
          l.firstWhere((s) => s.tag.label == label).score;

      // Souvenir ANTÉRIEUR à la naissance : mêmes signaux pour les deux, donc
      // même score — l'enfant ne reçoit aucun coup de pouce.
      final before = suggestPeople(
        memories: memories,
        people: people,
        alreadySelected: const {},
        date: DateTime(2026, 5, 10),
      );
      expect(scoreOf(before, 'Noé'), scoreOf(before, 'Papa'));

      // Souvenir POSTÉRIEUR : l'enfant du carnet passe devant.
      final after = suggestPeople(
        memories: memories,
        people: people,
        alreadySelected: const {},
        date: DateTime(2027, 6, 1),
      );
      expect(scoreOf(after, 'Noé'), greaterThan(scoreOf(after, 'Papa')));
      expect(after.first.tag.label, 'Noé');
    });

    test('au plus `limit` propositions', () {
      final memories = [
        for (var i = 0; i < 10; i++)
          _memory(
            id: 'm$i',
            date: DateTime(2026, 4, i + 1),
            people: ['A', 'B', 'C', 'D', 'E'],
          ),
      ];
      final out = suggestPeople(
        memories: memories,
        people: ['A', 'B', 'C', 'D', 'E'].map(_person).toList(),
        alreadySelected: const {},
        date: DateTime(2026, 4, 5),
      );
      expect(out.length, 3);
    });
  });
}
