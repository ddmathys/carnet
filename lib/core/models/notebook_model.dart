import 'package:cloud_firestore/cloud_firestore.dart';
import '../constants/notebook_types.dart';

class NotebookModel {
  final String id;
  final String userId;
  final String type; // enfant|voyage|famille|grossesse|scolaire|libre
  final String title;
  final String coverColor;
  final String? coverPhotoUrl;

  // enfant only
  final String? companion;
  final String? companionName;

  // enfant + grossesse
  final DateTime? birthdate;
  final String? gender; // 'boy' | 'girl'

  // voyage
  final String? destination;

  // grossesse
  final DateTime? expectedDate;

  // famille
  final String? recipient;
  final String? bookFrequency; // monthly|quarterly|annual

  final DateTime? lastMemoryAt;
  final int memoriesCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Sharing
  final List<String> sharedWith;     // UIDs of collaborators (not including owner)
  final List<String> invitedEmails;  // Pending email invitations

  const NotebookModel({
    required this.id,
    required this.userId,
    required this.type,
    required this.title,
    required this.coverColor,
    this.coverPhotoUrl,
    this.companion,
    this.companionName,
    this.birthdate,
    this.gender,
    this.destination,
    this.expectedDate,
    this.recipient,
    this.bookFrequency,
    this.lastMemoryAt,
    this.memoriesCount = 0,
    required this.createdAt,
    required this.updatedAt,
    this.sharedWith = const [],
    this.invitedEmails = const [],
  });

  bool get isShared => sharedWith.isNotEmpty || invitedEmails.isNotEmpty;
  bool isOwner(String uid) => userId == uid;

  factory NotebookModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return NotebookModel(
      id: doc.id,
      userId: d['userId'] ?? '',
      type: d['type'] ?? 'enfant',
      title: d['title'] ?? d['firstName'] ?? '',
      coverColor: d['coverColor'] ?? '#7A9E7E',
      coverPhotoUrl: d['coverPhotoUrl'],
      companion: d['companion'] ?? d['animalId'],
      companionName: d['companionName'] ?? d['animalName'],
      birthdate: d['birthdate'] != null
          ? (d['birthdate'] as Timestamp).toDate()
          : d['birthDate'] != null
              ? (d['birthDate'] as Timestamp).toDate()
              : null,
      gender: d['gender'],
      destination: d['destination'],
      expectedDate: d['expectedDate'] != null
          ? (d['expectedDate'] as Timestamp).toDate()
          : null,
      recipient: d['recipient'],
      bookFrequency: d['bookFrequency'],
      lastMemoryAt: d['lastMemoryAt'] != null
          ? (d['lastMemoryAt'] as Timestamp).toDate()
          : null,
      memoriesCount: (d['memoriesCount'] as int?) ?? 0,
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      updatedAt: d['updatedAt'] != null
          ? (d['updatedAt'] as Timestamp).toDate()
          : DateTime.now(),
      sharedWith: List<String>.from(d['sharedWith'] ?? []),
      invitedEmails: List<String>.from(d['invitedEmails'] ?? []),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'userId': userId,
        'type': type,
        'title': title,
        'coverColor': coverColor,
        if (coverPhotoUrl != null) 'coverPhotoUrl': coverPhotoUrl,
        if (companion != null) 'companion': companion,
        if (companionName != null) 'companionName': companionName,
        if (birthdate != null) 'birthdate': Timestamp.fromDate(birthdate!),
        if (gender != null) 'gender': gender,
        if (destination != null) 'destination': destination,
        if (expectedDate != null)
          'expectedDate': Timestamp.fromDate(expectedDate!),
        if (recipient != null) 'recipient': recipient,
        if (bookFrequency != null) 'bookFrequency': bookFrequency,
        if (lastMemoryAt != null)
          'lastMemoryAt': Timestamp.fromDate(lastMemoryAt!),
        'memoriesCount': memoriesCount,
        'createdAt': Timestamp.fromDate(createdAt),
        'updatedAt': Timestamp.fromDate(updatedAt),
      };

  String get emoji => getNotebookTypeById(type).emoji;

  String get subtitle {
    switch (type) {
      case 'enfant':
        return age ?? 'Carnet enfant';
      case 'voyage':
        return destination ?? 'Carnet voyage';
      case 'famille':
        return recipient != null ? 'Pour ${recipient!}' : 'Gazette famille';
      case 'grossesse':
        return expectedDate != null
            ? 'Terme : ${_formatDate(expectedDate!)}'
            : 'Journal grossesse';
      case 'scolaire':
        return 'Années scolaires';
      default:
        return 'Carnet libre';
    }
  }

  String? get age {
    if (birthdate == null) return null;
    final now = DateTime.now();
    final months =
        (now.year - birthdate!.year) * 12 + now.month - birthdate!.month;
    if (months < 12) return '$months mois';
    final years = months ~/ 12;
    final rem = months % 12;
    if (rem == 0) return '$years an${years > 1 ? 's' : ''}';
    return '$years an${years > 1 ? 's' : ''} et $rem mois';
  }

  int? get ageInMonths {
    if (birthdate == null) return null;
    final now = DateTime.now();
    return (now.year - birthdate!.year) * 12 + now.month - birthdate!.month;
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
