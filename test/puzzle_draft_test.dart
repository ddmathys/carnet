import 'package:flutter_test/flutter_test.dart';

import 'package:bloom/core/models/puzzle_draft.dart';
import 'package:bloom/core/services/puzzle_quality_service.dart';

/// Brouillon de puzzle : ce que le dashboard relit pour proposer « Reprendre ».
/// Un champ perdu ici, c'est un puzzle qu'on ne peut plus reprendre.
void main() {
  PuzzleDraft draft({
    String size = '500',
    String? memoryId,
    int w = 4032,
    int h = 3024,
  }) =>
      PuzzleDraft(
        id: 'd1',
        userId: 'u1',
        photoUrl: 'https://backend/api/video/puzzle-photo?k=abc',
        size: size,
        photoW: w,
        photoH: h,
        memoryId: memoryId,
        photoIndex: memoryId == null ? null : 2,
        updatedAt: DateTime(2026, 10, 9, 18, 30),
      );

  test('tout ce qui sert à reprendre le puzzle part dans Firestore', () {
    final map = draft(memoryId: 'm1').toMap();
    expect(map['userId'], 'u1');
    expect(map['photoUrl'], 'https://backend/api/video/puzzle-photo?k=abc');
    expect(map['size'], '500');
    expect(map['photoW'], 4032);
    expect(map['photoH'], 3024);
    expect(map['memoryId'], 'm1');
    expect(map['photoIndex'], 2);
    expect(map['status'], 'draft');
    // L'horodatage est posé par le serveur (FieldValue), jamais par le client.
    expect(map.containsKey('updatedAt'), isTrue);
  });

  test('une photo de la galerie n\'a pas de souvenir derrière', () {
    final d = draft();
    expect(d.fromMemory, isFalse);
    expect(d.photoIndex, isNull);
    expect(draft(memoryId: 'm1').fromMemory, isTrue);
  });

  test('les dimensions permettent de réafficher le contrôle de résolution', () {
    expect(draft().dims, (w: 4032, h: 3024));
    // Dimensions inconnues (vieux brouillon) : pas de faux (0, 0), qui
    // ferait croire à une photo minuscule et bloquerait toutes les tailles.
    expect(draft(w: 0, h: 0).dims, isNull);
  });

  test('la taille enregistrée reste commandable avec cette photo', () {
    // 4032 px de large : le 252 et le 500 passent, le 1000 non (il lui faut
    // ≈4518 px au seuil de 150 DPI) — c'est ce que la reprise revérifie
    // avant de réafficher la taille du brouillon.
    final dims = draft().dims;
    final quality = PuzzleQualityService.evaluateAll(dims);
    expect(quality['500']?.isOrderable, isTrue);
    expect(quality['1000']?.isOrderable, isFalse);
  });
}
