import 'package:cloud_firestore/cloud_firestore.dart';

/// Écritures Firestore par lots, en respectant le plafond d'un `WriteBatch`.
///
/// Firestore refuse un batch de plus de 500 opérations : il échoue **en bloc**,
/// rien n'est écrit. Tous les parcours « tous les souvenirs portant ce tag »
/// passaient par un batch unique — un tag « Léa » nourri pendant trois ans en
/// dépasse largement, et le renommage, la suppression de tag et surtout la
/// RÉVOCATION D'UN PARTAGE échouaient alors silencieusement : l'interface
/// retirait la personne de la liste, mais son uid restait inscrit dans le
/// `sharedWith` des souvenirs, donc son accès avec (audit du 01.10.26).
///
/// Le découpage à 400 laisse de la marge sous le plafond réel, comme le fait
/// déjà le backend (`backend/api/tag/[action].ts`).
class ChunkedWriter {
  ChunkedWriter([FirebaseFirestore? db])
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// Même taille de lot que côté backend.
  static const int chunkSize = 400;

  WriteBatch? _batch;
  int _pending = 0;

  /// Nombre total d'opérations ajoutées depuis la création.
  int total = 0;

  Future<void> update(
      DocumentReference<Object?> ref, Map<String, Object?> data) async {
    (_batch ??= _db.batch()).update(ref, data);
    await _added();
  }

  Future<void> delete(DocumentReference<Object?> ref) async {
    (_batch ??= _db.batch()).delete(ref);
    await _added();
  }

  Future<void> _added() async {
    _pending++;
    total++;
    if (_pending >= chunkSize) await flush();
  }

  /// Envoie ce qui reste. À appeler une fois le parcours terminé — un oubli
  /// perdrait les dernières écritures.
  Future<void> flush() async {
    final batch = _batch;
    if (batch == null || _pending == 0) return;
    _batch = null;
    _pending = 0;
    await batch.commit();
  }
}
