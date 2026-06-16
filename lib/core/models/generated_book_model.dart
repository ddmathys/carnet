import 'package:cloud_firestore/cloud_firestore.dart';

/// Un livre généré (PDF) conservé dans l'historique du carnet.
/// Collection Firestore dédiée `generatedBooks` (distincte de `books` qui
/// sert aux histoires IA).
class GeneratedBookModel {
  final String id;
  final String userId;
  final String notebookId;
  final String title;
  final String? subtitle;
  final String format; // 'digital' | 'printed'
  final String coverType; // 'soft' | 'hard'
  final String pdfUrl;
  final String storagePath; // chemin Storage pour suppression
  final int memoriesCount;
  final DateTime createdAt;
  final String? orderId; // si format == 'printed'

  const GeneratedBookModel({
    required this.id,
    required this.userId,
    required this.notebookId,
    required this.title,
    this.subtitle,
    required this.format,
    required this.coverType,
    required this.pdfUrl,
    required this.storagePath,
    required this.memoriesCount,
    required this.createdAt,
    this.orderId,
  });

  bool get isPrinted => format == 'printed';

  factory GeneratedBookModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return GeneratedBookModel(
      id: doc.id,
      userId: d['userId'] ?? '',
      notebookId: d['notebookId'] ?? '',
      title: d['title'] ?? 'Livre',
      subtitle: d['subtitle'],
      format: d['format'] ?? 'digital',
      coverType: d['coverType'] ?? 'soft',
      pdfUrl: d['pdfUrl'] ?? '',
      storagePath: d['storagePath'] ?? '',
      memoriesCount: (d['memoriesCount'] as num?)?.toInt() ?? 0,
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      orderId: d['orderId'],
    );
  }

  Map<String, dynamic> toFirestore() => {
        'userId': userId,
        'notebookId': notebookId,
        'title': title,
        'subtitle': subtitle,
        'format': format,
        'coverType': coverType,
        'pdfUrl': pdfUrl,
        'storagePath': storagePath,
        'memoriesCount': memoriesCount,
        'createdAt': Timestamp.fromDate(createdAt),
        'orderId': orderId,
      };
}
