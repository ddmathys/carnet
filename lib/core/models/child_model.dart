import 'package:cloud_firestore/cloud_firestore.dart';

class ChildModel {
  final String id;
  final String parentId;
  final String firstName;
  final DateTime birthDate;
  final String animalId;
  final String animalName;
  final String coverColor;
  final String gender; // 'boy' | 'girl'

  const ChildModel({
    required this.id,
    required this.parentId,
    required this.firstName,
    required this.birthDate,
    required this.animalId,
    required this.animalName,
    required this.coverColor,
    required this.gender,
  });

  factory ChildModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ChildModel(
      id: doc.id,
      parentId: data['parentId'] ?? '',
      firstName: data['firstName'] ?? '',
      birthDate: (data['birthDate'] as Timestamp).toDate(),
      animalId: data['animalId'] ?? 'fox',
      animalName: data['animalName'] ?? 'Roux',
      coverColor: data['coverColor'] ?? '#7A9E7E',
      gender: data['gender'] ?? 'boy',
    );
  }

  Map<String, dynamic> toFirestore() => {
        'parentId': parentId,
        'firstName': firstName,
        'birthDate': Timestamp.fromDate(birthDate),
        'animalId': animalId,
        'animalName': animalName,
        'coverColor': coverColor,
        'gender': gender,
      };

  String get age {
    final now = DateTime.now();
    final months = (now.year - birthDate.year) * 12 + now.month - birthDate.month;
    if (months < 12) return '$months mois';
    final years = months ~/ 12;
    final remainingMonths = months % 12;
    if (remainingMonths == 0) return '$years an${years > 1 ? 's' : ''}';
    return '$years an${years > 1 ? 's' : ''} et $remainingMonths mois';
  }

  int get ageInMonths {
    final now = DateTime.now();
    return (now.year - birthDate.year) * 12 + now.month - birthDate.month;
  }
}
