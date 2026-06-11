import 'package:cloud_firestore/cloud_firestore.dart';

class BookModel {
  final String id;
  final String notebookId;
  final String userId;
  final String status; // 'draft' | 'ready' | 'ordered' | 'shipped'
  final String? pdfUrl;
  final int memoriesCount;
  final String format; // 'digital' | 'printed' | 'gift'
  final double? price;
  final String? orderRef;
  final List<Map<String, String>> chapters;
  final DateTime createdAt;
  final DateTime updatedAt;

  const BookModel({
    required this.id,
    required this.notebookId,
    required this.userId,
    required this.status,
    this.pdfUrl,
    required this.memoriesCount,
    required this.format,
    this.price,
    this.orderRef,
    required this.chapters,
    required this.createdAt,
    required this.updatedAt,
  });

  factory BookModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return BookModel(
      id: doc.id,
      notebookId: d['notebookId'] ?? '',
      userId: d['userId'] ?? '',
      status: d['status'] ?? 'draft',
      pdfUrl: d['pdfUrl'],
      memoriesCount: (d['memoriesCount'] as int?) ?? 0,
      format: d['format'] ?? 'digital',
      price: (d['price'] as num?)?.toDouble(),
      orderRef: d['orderRef'],
      chapters: List<Map<String, String>>.from(
        (d['chapters'] as List<dynamic>? ?? []).map(
          (c) => Map<String, String>.from(c as Map),
        ),
      ),
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      updatedAt: d['updatedAt'] != null
          ? (d['updatedAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'notebookId': notebookId,
        'userId': userId,
        'status': status,
        'pdfUrl': pdfUrl,
        'memoriesCount': memoriesCount,
        'format': format,
        'price': price,
        'orderRef': orderRef,
        'chapters': chapters,
        'createdAt': Timestamp.fromDate(createdAt),
        'updatedAt': Timestamp.fromDate(updatedAt),
      };
}
