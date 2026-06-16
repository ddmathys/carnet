import 'dart:async';
import 'dart:typed_data';

import 'package:record_platform_interface/record_platform_interface.dart';

/// Implémentation Linux factice du plugin `record`.
///
/// La version publiée sur pub.dev (record_linux 0.7.2) n'implémente pas
/// `startStream` ajouté dans record_platform_interface ^1.6.0 (requis par
/// record_android). Comme le dart_plugin_registrant importe cette classe même
/// pour un build Android, le 0.7.2 fait échouer la compilation. L'app ne tourne
/// jamais sous Linux : toutes les méthodes lèvent une erreur.
class RecordLinux extends RecordPlatform {
  static void registerWith() {
    RecordPlatform.instance = RecordLinux();
  }

  Never _unsupported() =>
      throw UnsupportedError('Audio recording is not supported on Linux.');

  @override
  Future<void> create(String recorderId) async => _unsupported();

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async =>
      _unsupported();

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async =>
      _unsupported();

  @override
  Future<String?> stop(String recorderId) async => _unsupported();

  @override
  Future<void> pause(String recorderId) async => _unsupported();

  @override
  Future<void> resume(String recorderId) async => _unsupported();

  @override
  Future<bool> isRecording(String recorderId) async => _unsupported();

  @override
  Future<bool> isPaused(String recorderId) async => _unsupported();

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      _unsupported();

  @override
  Future<void> dispose(String recorderId) async => _unsupported();

  @override
  Future<Amplitude> getAmplitude(String recorderId) async => _unsupported();

  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async =>
      _unsupported();

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async =>
      _unsupported();

  @override
  Future<void> cancel(String recorderId) async => _unsupported();

  @override
  Stream<RecordState> onStateChanged(String recorderId) => _unsupported();
}
