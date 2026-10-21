import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:bloom/core/models/memory_model.dart';
import 'package:bloom/core/models/tag_model.dart';
import 'package:bloom/core/services/book_nudge.dart';
import 'package:bloom/core/services/photo_focus_service.dart';

TagModel _child(String label,
        {required DateTime birthdate, String owner = 'u1'}) =>
    TagModel(
      id: label.toLowerCase(),
      userId: owner,
      label: label,
      kind: 'enfant',
      birthdate: birthdate,
      createdAt: DateTime(2020, 1, 1),
    );

List<MemoryModel> _memories(int n,
        {String owner = 'u1',
        List<String> tagIds = const [],
        DateTime? date,
        DateTime? createdAt}) =>
    [
      for (var i = 0; i < n; i++)
        MemoryModel(
          id: '$owner-$i-${tagIds.join()}',
          notebookId: 'nb',
          userId: owner,
          type: 'anecdote',
          date: date ?? DateTime(2026, 3, 1),
          rawContent: '',
          tagIds: tagIds,
          createdAt: createdAt ?? DateTime(2026, 3, 1),
        ),
    ];

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  group('BookNudge.pick', () {
    final now = DateTime(2026, 10, 21);

    test('rien sous les seuils', () {
      final out = BookNudge.pick(
        uid: 'u1',
        memories: _memories(10),
        ownTags: const [],
        sharedTags: const [],
        now: now,
      );
      expect(out, isNull);
    });

    test('anniversaire dans les 30 jours passe en premier', () {
      final lea = _child('Léa', birthdate: DateTime(2023, 11, 5));
      final out = BookNudge.pick(
        uid: 'u1',
        memories: [..._memories(50), ..._memories(15, tagIds: ['léa'])],
        ownTags: [lea],
        sharedTags: const [],
        now: now,
      );
      expect(out?.id, 'birthday:léa:2026');
      expect(out?.title, contains('3 ans'));
      expect(out?.giftFirst, isFalse);
    });

    test('un anniversaire mis en sourdine laisse la place au suivant', () {
      final lea = _child('Léa', birthdate: DateTime(2023, 11, 5));
      final out = BookNudge.pick(
        uid: 'u1',
        memories: [..._memories(50), ..._memories(15, tagIds: ['léa'])],
        ownTags: [lea],
        sharedTags: const [],
        now: now,
        dismissed: {'birthday:léa:2026'},
      );
      expect(out?.id, startsWith('threshold:'));
    });

    test('livre de l\'année en novembre', () {
      final out = BookNudge.pick(
        uid: 'u1',
        memories: _memories(25),
        ownTags: const [],
        sharedTags: const [],
        now: DateTime(2026, 11, 10),
      );
      expect(out?.id, 'year:2026');
    });

    test('souvenirs partagés : l\'offrir en premier', () {
      final tag = TagModel(
        id: 'famille',
        userId: 'parent',
        label: 'Famille',
        kind: 'personne',
        createdAt: DateTime(2020),
      );
      final out = BookNudge.pick(
        uid: 'mamie',
        memories: _memories(20, owner: 'parent', tagIds: ['famille']),
        ownTags: const [],
        sharedTags: [tag],
        now: now,
      );
      expect(out?.id, 'shared:famille:0');
      expect(out?.giftFirst, isTrue);
    });

    test('seuil compté depuis la dernière commande de livre', () {
      final out = BookNudge.pick(
        uid: 'u1',
        memories: [
          ..._memories(100, createdAt: DateTime(2026, 1, 1)),
          ..._memories(10, tagIds: ['x'], createdAt: DateTime(2026, 9, 1)),
        ],
        ownTags: const [],
        sharedTags: const [],
        now: now,
        lastBookOrderAt: DateTime(2026, 6, 1),
      );
      expect(out, isNull);
    });
  });

  group('PhotoFocusService.focusFromFaces', () {
    test('aucun visage → pas de point', () {
      expect(
          PhotoFocusService.focusFromFaces(const [],
              width: 100, height: 100, id: 'p'),
          isNull);
    });

    test('ignore les petits visages d\'arrière-plan', () {
      final f = PhotoFocusService.focusFromFaces(
        const [
          Rect.fromLTWH(10, 10, 40, 40), // visage principal
          Rect.fromLTWH(180, 180, 8, 8), // passant au fond
        ],
        width: 200,
        height: 200,
        id: 'p',
      );
      expect(f!.x, closeTo(0.15, 1e-9));
      expect(f.y, closeTo(0.15, 1e-9));
    });

    test('centre de l\'ensemble pour plusieurs visages', () {
      final f = PhotoFocusService.focusFromFaces(
        const [Rect.fromLTWH(0, 0, 20, 20), Rect.fromLTWH(80, 0, 20, 20)],
        width: 100,
        height: 100,
        id: 'p',
      );
      expect(f!.x, closeTo(0.5, 1e-9));
      expect(f.y, closeTo(0.1, 1e-9));
    });
  });
}
