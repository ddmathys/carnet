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
      weightKg: (d['weightKg'] as num?)?.toDouble(),
      heightCm: (d['heightCm'] as num?)?.toDouble(),
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
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
        'weightKg': weightKg,
        'heightCm': heightCm,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}
