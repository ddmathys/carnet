/// Point de recadrage d'une photo : l'endroit qui doit rester visible quand la
/// photo est rognée pour remplir une case d'un autre format (toutes les photos
/// du livre sont posées en `BoxFit.cover`, donc toutes rognées).
///
/// Coordonnées normalisées : x de 0 (bord gauche) à 1 (bord droit), y de 0
/// (bord haut) à 1 (bord bas). Posé par `/api/ai/photo-focus` (Gemini Flash),
/// stocké sur le souvenir dans `mediaFocus` et jamais recalculé pour une photo
/// déjà analysée.
///
/// `id` est l'identifiant STABLE de la photo — clé R2, ou URL Firebase pour
/// les souvenirs d'avant la bascule (voir `rawMediaIdsOf`). Le champ est une
/// LISTE côté Firestore et non une map, parce que ces identifiants contiennent
/// des '/' et des '.', mal venus comme noms de champs (même raison que
/// `photoTexts` dans `bookDrafts`).
class PhotoFocus {
  final String id;
  final double x;
  final double y;

  const PhotoFocus({required this.id, required this.x, required this.y});

  /// Converti en alignement pour un `BoxFit.cover` : l'alignement va de -1 à
  /// +1 et décide quelle partie de l'image débordante reste dans la case.
  ///
  /// Convention Flutter (y vers le BAS) : -1 = haut, +1 = bas. Le paquet `pdf`
  /// prend l'axe inverse (`Alignment.topCenter` y vaut +1) — son appelant
  /// passe donc `-alignY`.
  double get alignX => (x * 2 - 1).clamp(-1.0, 1.0);
  double get alignY => (y * 2 - 1).clamp(-1.0, 1.0);

  static PhotoFocus? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final x = (raw['x'] as num?)?.toDouble();
    final y = (raw['y'] as num?)?.toDouble();
    if (id is! String || id.isEmpty || x == null || y == null) return null;
    return PhotoFocus(
      id: id,
      x: x.clamp(0.0, 1.0),
      y: y.clamp(0.0, 1.0),
    );
  }

  Map<String, dynamic> toMap() => {'id': id, 'x': x, 'y': y};

  static List<PhotoFocus> listFrom(Object? raw) {
    if (raw is! List) return const [];
    final out = <PhotoFocus>[];
    for (final e in raw) {
      final f = fromMap(e);
      if (f != null) out.add(f);
    }
    return out;
  }
}
