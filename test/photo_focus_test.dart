import 'package:flutter_test/flutter_test.dart';
import 'package:bloom/core/models/photo_focus.dart';

/// Le signe de l'axe vertical est le seul piège de la conversion : l'axe du
/// paquet `pdf` MONTE (Alignment.topCenter vaut y = +1), celui de PhotoFocus
/// descend (y = 0 en haut de l'image). Une inversion ici recadrerait toutes
/// les photos du livre à l'envers, sans rien casser visiblement ailleurs.
void main() {
  group('PhotoFocus → alignement', () {
    test('le centre ne décale rien', () {
      const f = PhotoFocus(id: 'k', x: 0.5, y: 0.5);
      expect(f.alignX, 0.0);
      expect(f.alignY, 0.0);
    });

    test('un sujet en haut à gauche tire le cadrage vers le haut à gauche', () {
      const f = PhotoFocus(id: 'k', x: 0.0, y: 0.0);
      expect(f.alignX, -1.0);
      // Convention Flutter (y vers le bas) : -1 = haut. Le rendu PDF passe
      // -alignY, donc +1 = haut côté `pdf`.
      expect(f.alignY, -1.0);
    });

    test('un sujet en bas à droite tire le cadrage vers le bas à droite', () {
      const f = PhotoFocus(id: 'k', x: 1.0, y: 1.0);
      expect(f.alignX, 1.0);
      expect(f.alignY, 1.0);
    });

    test('un visage au tiers haut reste dans le cadre', () {
      const f = PhotoFocus(id: 'k', x: 0.5, y: 0.25);
      expect(f.alignY, -0.5);
    });
  });

  group('PhotoFocus.listFrom', () {
    test('ignore les entrées inexploitables sans tout perdre', () {
      final list = PhotoFocus.listFrom([
        {'id': 'photos/a.jpg', 'x': 0.4, 'y': 0.3},
        {'id': '', 'x': 0.4, 'y': 0.3}, // identifiant vide
        {'id': 'photos/b.jpg'}, // coordonnées absentes
        'pas une map',
      ]);
      expect(list.length, 1);
      expect(list.first.id, 'photos/a.jpg');
    });

    test('borne des coordonnées hors plage', () {
      final list = PhotoFocus.listFrom([
        {'id': 'k', 'x': 1.8, 'y': -0.4},
      ]);
      expect(list.single.x, 1.0);
      expect(list.single.y, 0.0);
    });

    test('un souvenir sans mediaFocus donne une liste vide', () {
      expect(PhotoFocus.listFrom(null), isEmpty);
    });
  });
}
