import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/memory_model.dart';
import '../models/photo_focus.dart';
import 'book_pdf_service.dart' show rawMediaIdsOf;
import 'photo_service.dart';

/// Points de recadrage des photos (voir [PhotoFocus]).
///
/// Toutes les photos d'un livre sont posées en `BoxFit.cover` : elles sont donc
/// TOUTES rognées pour remplir leur case. Sans information sur le sujet, le
/// moteur rognait au centre (ou en haut pour une verticale, en pariant sur un
/// visage) — et coupait régulièrement un visage décentré, en pleine page, sur
/// un objet imprimé que le client ne peut plus corriger.
///
/// Depuis le 21.10.26, le point est calculé SUR LE TÉLÉPHONE par la détection
/// de visages de ML Kit — il l'était avant par Gemini, côté serveur. Aucune
/// photo ne part donc chez un prestataire d'IA, et il ne s'agit que de
/// DÉTECTION (où sont les visages) : aucune reconnaissance de qui que ce soit.
///
/// Le point trouvé est stocké sur le souvenir (`mediaFocus`) et relu ensuite :
/// régénérer un livre, ou en faire un deuxième, ne refait pas l'analyse. Une
/// photo sans visage n'est pas stockée — le moteur garde alors son cadrage par
/// défaut — mais n'est pas réanalysée pendant la session.
class PhotoFocusService {
  /// Téléchargements simultanés — même borne que le moteur du livre.
  static const int _parallelDownloads = 6;

  /// Un visage plus petit que cette fraction du plus grand est un visage
  /// d'arrière-plan (un passant, un portrait au mur) : il ne doit pas tirer
  /// le cadrage vers lui.
  static const double _minFaceRatio = 0.25;

  /// Photos déjà analysées sans visage pendant cette session.
  static final Set<String> _noSubject = {};

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
  /// l'éditeur d'aperçu n'a pas retirées).
  ///
  /// [bytesCache] est le cache d'octets du livre, indexé par URL signée : les
  /// photos téléchargées ici y sont déposées, et le moteur du PDF ne les
  /// retélécharge pas.
  ///
  /// Tolérant à l'échec par construction : ce qui n'a pas pu être analysé
  /// (réseau coupé, photo illisible) est simplement absent du résultat, et le
  /// moteur retombe sur son cadrage par défaut. Un livre part toujours.
  static Future<Map<String, PhotoFocus>> ensure(
    List<MemoryModel> memories, {
    Set<String>? onlyIds,
    Map<String, Uint8List>? bytesCache,
    void Function(int done, int total)? onProgress,
  }) async {
    final result = known(memories);
    final cache = bytesCache ?? <String, Uint8List>{};

    // Photos à analyser, avec leur URL signée (même ordre que rawMediaIdsOf).
    final todo = <({String memoryId, String id, String url})>[];
    for (final m in memories) {
      final ids = rawMediaIdsOf(m);
      if (!ids.any((id) => _needsAnalysis(id, result, onlyIds))) continue;
      List<String> urls;
      try {
        urls = await PhotoService.resolvePhotoUrls(m);
      } catch (_) {
        continue;
      }
      // URLs non alignées sur les identifiants (repli de resolvePhotoUrls) :
      // on ne risque pas d'attribuer le point d'une photo à une autre.
      if (urls.length != ids.length) continue;
      for (var i = 0; i < ids.length; i++) {
        if (_needsAnalysis(ids[i], result, onlyIds)) {
          todo.add((memoryId: m.id, id: ids[i], url: urls[i]));
        }
      }
    }
    if (todo.isEmpty) return result;

    final detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.05,
      ),
    );
    final tmpDir = await getTemporaryDirectory();
    final fresh = <String, List<PhotoFocus>>{}; // memoryId -> points
    var done = 0;
    onProgress?.call(0, todo.length);

    try {
      for (var i = 0; i < todo.length; i += _parallelDownloads) {
        final slice = todo.sublist(
            i,
            i + _parallelDownloads > todo.length
                ? todo.length
                : i + _parallelDownloads);
        final bytesList = await Future.wait(
            slice.map((t) => _bytesFor(t.url, cache)));
        // ML Kit traite une image à la fois : la détection reste séquentielle.
        for (var j = 0; j < slice.length; j++) {
          final bytes = bytesList[j];
          final t = slice[j];
          if (bytes != null) {
            final f = await _detect(detector, tmpDir, t.id, bytes);
            if (f != null) {
              result[t.id] = f;
              (fresh[t.memoryId] ??= []).add(f);
            } else {
              _noSubject.add(t.id);
            }
          }
          done++;
        }
        onProgress?.call(done, todo.length);
      }
    } finally {
      await detector.close();
    }

    await _persist(fresh);
    return result;
  }

  static bool _needsAnalysis(
      String id, Map<String, PhotoFocus> known, Set<String>? onlyIds) {
    if (id.isEmpty) return false;
    if (known.containsKey(id) || _noSubject.contains(id)) return false;
    return onlyIds == null || onlyIds.contains(id);
  }

  static Future<Uint8List?> _bytesFor(
      String url, Map<String, Uint8List> cache) async {
    final hit = cache[url];
    if (hit != null) return hit;
    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      cache[url] = resp.bodyBytes;
      return resp.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// Centre du groupe de visages principaux, normalisé 0..1 — null si la
  /// photo n'a aucun visage exploitable (ou n'a pas pu être lue).
  static Future<PhotoFocus?> _detect(FaceDetector detector, Directory tmpDir,
      String id, Uint8List bytes) async {
    // ML Kit lit un fichier (un JPEG brut n'est pas accepté en mémoire).
    final file = File(
        '${tmpDir.path}/focus_${DateTime.now().microsecondsSinceEpoch}.jpg');
    try {
      final size = await _imageSize(bytes);
      if (size == null) return null;
      await file.writeAsBytes(bytes, flush: true);
      final faces =
          await detector.processImage(InputImage.fromFilePath(file.path));
      return focusFromFaces(
        [for (final f in faces) f.boundingBox],
        width: size.width,
        height: size.height,
        id: id,
      );
    } catch (_) {
      return null;
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static Future<({double width, double height})?> _imageSize(
      Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = (
        width: frame.image.width.toDouble(),
        height: frame.image.height.toDouble()
      );
      frame.image.dispose();
      codec.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  /// Point de recadrage à partir des rectangles de visages détectés : le
  /// centre de l'enveloppe des visages principaux (les petits visages
  /// d'arrière-plan sont ignorés, cf. [_minFaceRatio]). Public pour les tests.
  static PhotoFocus? focusFromFaces(
    List<ui.Rect> faces, {
    required double width,
    required double height,
    required String id,
  }) {
    if (faces.isEmpty || width <= 0 || height <= 0) return null;
    final biggest =
        faces.map((r) => r.width * r.height).reduce((a, b) => a > b ? a : b);
    final main =
        faces.where((r) => r.width * r.height >= biggest * _minFaceRatio);
    final box = main.reduce((a, b) => a.expandToInclude(b));
    return PhotoFocus(
      id: id,
      x: (box.center.dx / width).clamp(0.0, 1.0),
      y: (box.center.dy / height).clamp(0.0, 1.0),
    );
  }

  /// Écrit les nouveaux points sur leurs souvenirs. Une écriture refusée (droits,
  /// hors ligne) ne coûte que la réanalyse au prochain livre.
  static Future<void> _persist(Map<String, List<PhotoFocus>> fresh) async {
    for (final e in fresh.entries) {
      try {
        await FirebaseFirestore.instance
            .collection('memories')
            .doc(e.key)
            .update({
          'mediaFocus':
              FieldValue.arrayUnion([for (final f in e.value) f.toMap()]),
        });
      } catch (_) {}
    }
  }

  /// Recopie les points trouvés sur les souvenirs en mémoire : le moteur de
  /// mise en page lit le point sur le souvenir (`focusFor`).
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
}
