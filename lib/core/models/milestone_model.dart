import 'package:cloud_firestore/cloud_firestore.dart';

class MilestoneModel {
  final String id;
  final String childId;
  final String type;
  final DateTime date;
  final String rawContent;
  final String? aiNarration;
  final String? photoUrl;
  final DateTime createdAt;

  const MilestoneModel({
    required this.id,
    required this.childId,
    required this.type,
    required this.date,
    required this.rawContent,
    this.aiNarration,
    this.photoUrl,
    required this.createdAt,
  });

  factory MilestoneModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MilestoneModel(
      id: doc.id,
      childId: data['childId'] ?? '',
      type: data['type'] ?? 'note',
      date: (data['date'] as Timestamp).toDate(),
      rawContent: data['rawContent'] ?? '',
      aiNarration: data['aiNarration'],
      photoUrl: data['photoUrl'],
      createdAt: (data['createdAt'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'childId': childId,
        'type': type,
        'date': Timestamp.fromDate(date),
        'rawContent': rawContent,
        'aiNarration': aiNarration,
        'photoUrl': photoUrl,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}
