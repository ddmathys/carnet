import '../models/memory_model.dart';
import '../models/photo_focus.dart';
import 'backend_client.dart';
import 'book_pdf_service.dart' show rawMediaIdsOf;

/// Points de recadrage des photos (voir [PhotoFocus]).
///
/// Toutes les photos d'un livre sont posées en `BoxFit.cover` : elles sont donc
/// TOUTES rognées pour remplir leur case. Sans information sur le sujet, le
/// moteur rognait au centre (ou en haut pour une verticale, en pariant sur un
/// visage) — et coupait régulièrement un visage décentré, en pleine page, sur
/// un objet imprimé que le client ne peut plus corriger.
///
/// Le point est demandé UNE fois par photo à `/api/ai/photo-focus`, stocké sur
/// le souvenir (`mediaFocus`) et relu ensuite : régénérer un livre, ou en faire
/// un deuxième avec les mêmes photos, ne recoûte rien.
class PhotoFocusService {
  /// Aligné sur `MAX_IDS_PER_CALL` du backend : au-delà, le téléchargement des
  /// photos plus l'appel Gemini sortent du `maxDuration` de la fonction.
  static const int _chunkSize = 8;

  /// Lots en parallèle. Borné pour la même raison que le téléchargement des
  /// photos du livre : tout lancer d'un coup fait timeouter une partie des
  /// requêtes au hasard.
  static const int _parallelChunks = 3;

  /// Points déjà connus, lus sur les souvenirs — aucun appel réseau.
  static Map<String, PhotoFocus> known(List<MemoryModel> memories) {
    final out = <String, PhotoFocus>{};
    for (final m in memories) {
      for (final f in m.mediaFocus) {
        out[f.id] = f;
      }
    }
    return out;
  }

  /// Complète les points manquants puis renvoie l'ensemble (connus + nouveaux),
  /// indexé par identifiant stable de photo.
  ///
  /// [onlyIds] restreint l'analyse aux photos réellement imprimées (celles que
  /// l'éditeur d'aperçu n'a pas retirées) : on ne paie pas pour une photo qui
  /// ne sera pas dans le livre.
  ///
  /// Tolérant à l'échec par construction : ce qui n'a pas pu être analysé
  /// (réseau coupé, quota IA du jour atteint, photo illisible) est simplement
  /// absent du résultat, et le moteur retombe sur son cadrage par défaut. Un
  /// livre part donc toujours, jamais bloqué par l'IA.
  static Future<Map<String, PhotoFocus>> ensure(
    List<MemoryModel> memories, {
    Set<String>? onlyIds,
    void Function(int done, int total)? onProgress,
  }) async {
    final result = known(memories);

    // Lots à demander : (souvenir, jusqu'à _chunkSize photos non analysées).
    final chunks = <({String memoryId, List<String> ids})>[];
    for (final m in memories) {
      final missing = <String>[];
      for (final id in rawMediaIdsOf(m)) {
        if (id.isEmpty) continue;
        if (result.containsKey(id)) continue;
        if (onlyIds != null && !onlyIds.contains(id)) continue;
        missing.add(id);
      }
      for (var i = 0; i < missing.length; i += _chunkSize) {
        chunks.add((
          memoryId: m.id,
          ids: missing.sublist(
              i,
              i + _chunkSize > missing.length
                  ? missing.length
                  : i + _chunkSize),
        ));
      }
    }
    if (chunks.isEmpty) return result;

    var done = 0;
    final total = chunks.length;
    onProgress?.call(0, total);

    for (var i = 0; i < chunks.length; i += _parallelChunks) {
      final slice = chunks.sublist(
          i,
          i + _parallelChunks > chunks.length
              ? chunks.length
              : i + _parallelChunks);
      final answers = await Future.wait(slice.map(_fetchChunk));
      for (final found in answers) {
        for (final f in found) {
          result[f.id] = f;
        }
      }
      done += slice.length;
      onProgress?.call(done, total);
    }

    return result;
  }

  /// Recopie les points trouvés sur les souvenirs en mémoire : les documents
  /// chargés par l'écran datent d'AVANT l'écriture faite par le backend, et le
  /// moteur de mise en page lit le point sur le souvenir (`focusFor`).
  static List<MemoryModel> applied(
      List<MemoryModel> memories, Map<String, PhotoFocus> focus) {
    return [
      for (final m in memories)
        m.copyWith(mediaFocus: [
          // Repli sur ce que le souvenir portait déjà : [focus] ne couvre que
          // les souvenirs soumis à l'analyse, et un souvenir hors livre ne
          // doit pas perdre son point au passage.
          for (final id in rawMediaIdsOf(m))
            if ((focus[id] ?? m.focusFor(id)) case final f?) f
        ])
    ];
  }

  static Future<List<PhotoFocus>> _fetchChunk(
      ({String memoryId, List<String> ids}) chunk) async {
    try {
      final res = await BackendClient.postJson(
        '/api/ai/photo-focus',
        {'memoryId': chunk.memoryId, 'ids': chunk.ids},
      );
      return PhotoFocus.listFrom(res?['focus']);
    } catch (_) {
      return const [];
    }
  }
}
