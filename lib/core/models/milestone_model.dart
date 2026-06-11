import 'package:cloud_firestore/cloud_firestore.dart';

class MilestoneModel {
  final String id;
  final String childId;
  final String type;
  final String? subType;
  final DateTime date;
  final String datePrecision; // 'exact' | 'month' | 'quarter'
  final String? dateLabel;    // label lisible ex: "mars 2024", "T2 2024"
  final String rawContent;
  final String? aiNarration;
  final String? photoUrl;
  final double? weightKg;
  final double? heightCm;
  final DateTime createdAt;

  const MilestoneModel({
    required this.id,
    required this.childId,
    required this.type,
    this.subType,
    required this.date,
    this.datePrecision = 'exact',
    this.dateLabel,
    required this.rawContent,
    this.aiNarration,
    this.photoUrl,
    this.weightKg,
    this.heightCm,
    required this.createdAt,
  });

  factory MilestoneModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MilestoneModel(
      id: doc.id,
      childId: data['childId'] ?? '',
      type: data['type'] ?? 'anecdote',
      subType: data['subType'],
      date: (data['date'] as Timestamp).toDate(),
      datePrecision: data['datePrecision'] ?? 'exact',
      dateLabel: data['dateLabel'],
      rawContent: data['rawContent'] ?? '',
      aiNarration: data['aiNarration'],
      photoUrl: data['photoUrl'],
      weightKg: (data['weightKg'] as num?)?.toDouble(),
      heightCm: (data['heightCm'] as num?)?.toDouble(),
      createdAt: data['createdAt'] != null
          ? (data['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'childId': childId,
        'type': type,
        'subType': subType,
        'date': Timestamp.fromDate(date),
        'datePrecision': datePrecision,
        'dateLabel': dateLabel,
        'rawContent': rawContent,
        'aiNarration': aiNarration,
        'photoUrl': photoUrl,
        'weightKg': weightKg,
        'heightCm': heightCm,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}
