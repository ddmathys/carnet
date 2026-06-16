import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';

class AudioService {
  static final _storage = FirebaseStorage.instance;
  static const _uuid = Uuid();

  /// Upload a single voice memo, return its download URL.
  /// Stored at audio/{uid}/{notebookId}/{uuid}.m4a — mirrors PhotoService.
  static Future<String?> uploadMemoryAudio({
    required File audio,
    required String notebookId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    final ref = _storage.ref('audio/$uid/$notebookId/${_uuid.v4()}.m4a');
    final task = await ref.putFile(
      audio,
      SettableMetadata(contentType: 'audio/mp4'),
    );
    return await task.ref.getDownloadURL();
  }

  /// Delete a voice memo by its download URL. Silently ignores errors.
  static Future<void> deleteAudioByUrl(String? url) async {
    if (url == null || url.isEmpty) return;
    try {
      await _storage.refFromURL(url).delete();
    } catch (_) {}
  }
}
