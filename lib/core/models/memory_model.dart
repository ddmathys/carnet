import 'package:cloud_firestore/cloud_firestore.dart';

class MemoryModel {
  final String id;
  final String notebookId;
  final String type;
  final String? subType;
  final DateTime date;
  final String datePrecision; // 'exact' | 'month' | 'quarter'
  final String? dateLabel;
  final String? title;
  final String? location;
  final String rawContent;
  final String? aiNarration;
  final String? photoUrl;
  final List<String> mediaUrls;
  // Photos stockées sur Cloudflare R2 (clés d'objets, bucket privé). Nouveau
  // format sécurisé (URLs signées temporaires). Les anciens souvenirs n'ont que
  // `mediaUrls` (URLs Firebase permanentes) → double-lecture à l'affichage.
  final List<String> mediaKeys;
  final String? audioUrl;
  // Mémo vocal sur R2 (clé). Ancien format = `audioUrl` (Firebase) → double-lecture.
  final String? audioKey;
  final int? audioDurationMs;
  // Vidéos souvenir : on stocke les CLÉS des objets R2 (videos/{uid}/…/x.mp4),
  // pas les URLs — l'app et la page /watch reconstruisent l'URL publique depuis
  // l'hôte R2. `videoDurationsMs` est parallèle à `videoKeys` (best-effort).
  // Compat ascendante : les anciens souvenirs ont un `videoKey` unique.
  final List<String> videoKeys;
  final List<int> videoDurationsMs;
  final double? weightKg;
  final double? heightCm;
  final DateTime createdAt;

  const MemoryModel({
    required this.id,
    required this.notebookId,
    required this.type,
    this.subType,
    required this.date,
    this.datePrecision = 'exact',
    this.dateLabel,
    this.title,
    this.location,
    required this.rawContent,
    this.aiNarration,
    this.photoUrl,
    this.mediaUrls = const [],
    this.mediaKeys = const [],
    this.audioUrl,
    this.audioKey,
    this.audioDurationMs,
    this.videoKeys = const [],
    this.videoDurationsMs = const [],
    this.weightKg,
    this.heightCm,
    required this.createdAt,
  });

  factory MemoryModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return MemoryModel(
      id: doc.id,
      // Support both new (notebookId) and legacy (childId) field names
      notebookId: d['notebookId'] ?? d['childId'] ?? '',
      type: d['type'] ?? 'anecdote',
      subType: d['subType'],
      date: (d['date'] as Timestamp).toDate(),
      datePrecision: d['datePrecision'] ?? 'exact',
      dateLabel: d['dateLabel'],
      title: d['title'],
      location: d['location'],
      rawContent: d['rawContent'] ?? '',
      aiNarration: d['aiNarration'],
      photoUrl: d['photoUrl'],
      mediaUrls: List<String>.from(d['mediaUrls'] ?? []),
      mediaKeys: List<String>.from(d['mediaKeys'] ?? []),
      audioUrl: d['audioUrl'],
      audioKey: d['audioKey'],
      audioDurationMs: (d['audioDurationMs'] as num?)?.toInt(),
      videoKeys: _readVideoKeys(d),
      videoDurationsMs: _readVideoDurations(d),
      weightKg: (d['weightKg'] as num?)?.toDouble(),
      heightCm: (d['heightCm'] as num?)?.toDouble(),
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  /// Lit `videoKeys` (nouveau format multi) avec repli sur l'ancien `videoKey`.
  static List<String> _readVideoKeys(Map<String, dynamic> d) {
    final list = List<String>.from(d['videoKeys'] as List<dynamic>? ?? []);
    if (list.isEmpty) {
      final legacy = d['videoKey'] as String?;
      if (legacy != null && legacy.isNotEmpty) return [legacy];
    }
    return list;
  }

  static List<int> _readVideoDurations(Map<String, dynamic> d) {
    final raw = d['videoDurationsMs'] as List<dynamic>?;
    if (raw != null && raw.isNotEmpty) {
      return raw.map((e) => (e as num).toInt()).toList();
    }
    final legacy = (d['videoDurationMs'] as num?)?.toInt();
    return legacy != null ? [legacy] : [];
  }

  Map<String, dynamic> toFirestore() => {
        'notebookId': notebookId,
        'type': type,
        'subType': subType,
        'date': Timestamp.fromDate(date),
        'datePrecision': datePrecision,
        'dateLabel': dateLabel,
        'title': title,
        'location': location,
        'rawContent': rawContent,
        'aiNarration': aiNarration,
        'photoUrl': photoUrl,
        'mediaUrls': mediaUrls,
        'mediaKeys': mediaKeys,
        'audioUrl': audioUrl,
        'audioKey': audioKey,
        'audioDurationMs': audioDurationMs,
        'videoKeys': videoKeys,
        'videoDurationsMs': videoDurationsMs,
        // Miroir hérité (lu par d'anciens clients / la page /watch d'origine).
        'videoKey': videoKeys.isNotEmpty ? videoKeys.first : null,
        'videoDurationMs':
            videoDurationsMs.isNotEmpty ? videoDurationsMs.first : null,
        'weightKg': weightKg,
        'heightCm': heightCm,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}
