import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Un média reçu depuis le menu « Partager » d'Android.
///
/// `path` pointe vers une COPIE dans le cache de l'appli (voir `MainActivity`) :
/// le fichier d'origine appartient à Google Photos / la galerie et n'est lisible
/// qu'un court instant.
class SharedMediaItem {
  final String path;
  final String mimeType;

  const SharedMediaItem({required this.path, required this.mimeType});

  bool get isVideo => mimeType.toLowerCase().startsWith('video/');

  factory SharedMediaItem.fromMap(Map<dynamic, dynamic> map) => SharedMediaItem(
        path: (map['path'] as String?) ?? '',
        mimeType: (map['mimeType'] as String?) ?? '',
      );
}

/// Réception des photos / vidéos partagées vers Carnet.
///
/// Deux chemins d'arrivée, tous deux alimentés par `MainActivity` :
///  - appli fermée : les médias du lancement, récupérés une fois au démarrage
///    (`hasPending`, attendu par le splash) ;
///  - appli déjà ouverte : un flux (`stream`), écouté par `BloomApp`.
///
/// Dans les deux cas les médias sont mis de côté ici, puis consommés par
/// `MemoryCreateScreen` via `takePending()` — le formulaire de souvenir s'ouvre
/// avec les fichiers déjà attachés.
///
/// Android uniquement : sur iOS, recevoir un partage demande une extension
/// native (Share Extension) qui n'existe pas encore dans le projet.
class SharedMediaService {
  static const MethodChannel _channel =
      MethodChannel('ch.gravendev.bloom/shared_media');
  static const EventChannel _events =
      EventChannel('ch.gravendev.bloom/shared_media_events');

  static final StreamController<List<SharedMediaItem>> _controller =
      StreamController<List<SharedMediaItem>>.broadcast();

  /// Partages reçus pendant que l'appli tourne.
  static Stream<List<SharedMediaItem>> get stream => _controller.stream;

  static final List<SharedMediaItem> _pending = [];
  static Future<void>? _initialLoad;
  static bool _started = false;

  /// À appeler une fois au démarrage (`main`). Ne bloque pas : la copie des
  /// fichiers peut prendre un instant sur une grosse vidéo, le splash attend
  /// ensuite via `hasPending()`.
  static void init() {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    _initialLoad = _loadInitial();
    _events.receiveBroadcastStream().listen(
      (event) {
        final items = _parse(event);
        if (items.isEmpty) return;
        _pending
          ..clear()
          ..addAll(items);
        _controller.add(items);
      },
      onError: (_) {},
    );
  }

  static Future<void> _loadInitial() async {
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('getInitialSharedMedia');
      _pending.addAll(_parse(result));
    } catch (_) {
      // Canal absent (iOS, tests) : pas de partage entrant, c'est tout.
    }
  }

  static List<SharedMediaItem> _parse(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(SharedMediaItem.fromMap)
        .where((item) => item.path.isNotEmpty)
        .toList();
  }

  /// Y a-t-il des médias partagés en attente ? Attend la récupération initiale
  /// (démarrage à froid) avant de répondre.
  static Future<bool> hasPending() async {
    if (!_started) return false;
    await _initialLoad;
    return _pending.isNotEmpty;
  }

  /// Récupère les médias en attente ET vide la file : un partage n'est ingéré
  /// qu'une seule fois, même si l'écran de création est rouvert.
  static List<SharedMediaItem> takePending() {
    final items = List<SharedMediaItem>.from(_pending);
    _pending.clear();
    return items;
  }
}
