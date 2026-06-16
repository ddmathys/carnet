import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import 'audio_service.dart';

class PhotoService {
  static final _storage = FirebaseStorage.instance;
  static final _firestore = FirebaseFirestore.instance;
  static const _uuid = Uuid();

  /// Upload a single photo, return download URL.
  static Future<String?> uploadMemoryPhoto({
    required File photo,
    required String notebookId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    final ref = _storage.ref('photos/$uid/$notebookId/${_uuid.v4()}.jpg');
    final task = await ref.putFile(
        photo, SettableMetadata(contentType: 'image/jpeg'));
    return await task.ref.getDownloadURL();
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
      return <Future<void>>[
        ...urls.map(deletePhotoByUrl),
        AudioService.deleteAudioByUrl(data['audioUrl'] as String?),
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
      {String? audioUrl}) async {
    final allUrls = {
      if (photoUrl != null && photoUrl.isNotEmpty) photoUrl,
      ...mediaUrls,
    };
    await Future.wait([
      ...allUrls.map(deletePhotoByUrl),
      AudioService.deleteAudioByUrl(audioUrl),
      _firestore.collection('memories').doc(memoryId).delete(),
    ]);
  }
}
