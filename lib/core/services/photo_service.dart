import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:uuid/uuid.dart';
import 'audio_service.dart';
import 'video_service.dart';

class PhotoService {
  static final _storage = FirebaseStorage.instance;
  static final _firestore = FirebaseFirestore.instance;
  static const _uuid = Uuid();

  // Compression cible : ~2048 px sur le grand côté, qualité 85. Une photo de
  // téléphone (4000 px, ~5 Mo) tombe à ~2048 px / ~400–700 Ko — assez pour une
  // impression demi-page à 300 DPI, et 5–10× plus rapide à uploader.
  static const int _maxDimension = 2048;
  static const int _jpegQuality = 85;

  /// Upload a single photo, return download URL. The image is JPEG-compressed
  /// before upload; on compression failure the original file is sent instead.
  static Future<String?> uploadMemoryPhoto({
    required File photo,
    required String notebookId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    final ref = _storage.ref('photos/$uid/$notebookId/${_uuid.v4()}.jpg');
    final metadata = SettableMetadata(contentType: 'image/jpeg');
    final bytes = await _compress(photo);
    final task = bytes != null
        ? await ref.putData(bytes, metadata)
        : await ref.putFile(photo, metadata);
    return await task.ref.getDownloadURL();
  }

  /// Compress to JPEG. Returns null on failure so the caller can fall back to
  /// uploading the original untouched.
  static Future<Uint8List?> _compress(File photo) async {
    try {
      return await FlutterImageCompress.compressWithFile(
        photo.absolute.path,
        minWidth: _maxDimension,
        minHeight: _maxDimension,
        quality: _jpegQuality,
        format: CompressFormat.jpeg,
      );
    } catch (_) {
      return null;
    }
  }

  /// Upload multiple photos in parallel, return list of download URLs.
  static Future<List<String>> uploadMultiplePhotos({
    required List<File> photos,
    required String notebookId,
  }) async {
    final results = await Future.wait(
      photos.map((f) => uploadMemoryPhoto(photo: f, notebookId: notebookId)),
    );
    return results.whereType<String>().toList();
  }

  /// Delete a photo by its download URL. Silently ignores errors
  /// (already deleted, wrong URL, etc.).
  static Future<void> deletePhotoByUrl(String? url) async {
    if (url == null || url.isEmpty) return;
    try {
      await _storage.refFromURL(url).delete();
    } catch (_) {}
  }

  /// Delete all photos attached to memories in a notebook,
  /// then delete the memories and the notebook itself.
  static Future<void> deleteNotebookCascade(String notebookId) async {
    final memories = await _firestore
        .collection('memories')
        .where('notebookId', isEqualTo: notebookId)
        .get();

    // Delete all photos + voice memos from Storage
    final mediaFutures = memories.docs.expand((doc) {
      final data = doc.data();
      final urls = <String?>[
        data['photoUrl'] as String?,
        ...List<String>.from(data['mediaUrls'] as List<dynamic>? ?? []),
      ];
      final videoKeys = List<String>.from(
          data['videoKeys'] as List<dynamic>? ??
              [if (data['videoKey'] != null) data['videoKey']]);
      return <Future<void>>[
        ...urls.map(deletePhotoByUrl),
        AudioService.deleteAudioByUrl(data['audioUrl'] as String?),
        VideoService.deleteVideosByKeys(videoKeys),
      ];
    });
    await Future.wait(mediaFutures);

    // Delete memories from Firestore in batches
    const batchSize = 400;
    for (var i = 0; i < memories.docs.length; i += batchSize) {
      final batch = _firestore.batch();
      for (final doc in memories.docs.skip(i).take(batchSize)) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }

    // Delete notebook
    await _firestore.collection('notebooks').doc(notebookId).delete();
  }

  /// Delete a memory and ALL its photos (photoUrl + mediaUrls) + voice memo.
  static Future<void> deleteMemory(
      String memoryId, String? photoUrl, List<String> mediaUrls,
      {String? audioUrl, List<String> videoKeys = const []}) async {
    final allUrls = {
      if (photoUrl != null && photoUrl.isNotEmpty) photoUrl,
      ...mediaUrls,
    };
    await Future.wait([
      ...allUrls.map(deletePhotoByUrl),
      AudioService.deleteAudioByUrl(audioUrl),
      VideoService.deleteVideosByKeys(videoKeys),
      _firestore.collection('memories').doc(memoryId).delete(),
    ]);
  }
}
