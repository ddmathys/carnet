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
  // Vignette (photo de couverture choisie à la génération) — affichage seul
  // (« Mes livres »), sans usage impression. Null si couverture sans photo.
  // Clé R2 (photo récente) : résolue en URL signée à l'affichage — jamais une
  // URL signée stockée telle quelle, elle expire au bout d'1h (photo-play/
  // photo-sign, backend/api/video/[action].ts). `coverPhotoUrl` reste pour
  // les photos Firebase héritées (URL permanente, pas de clé R2 à résoudre).
  final String? coverPhotoKey;
  final String? coverPhotoUrl;

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
    this.coverPhotoKey,
    this.coverPhotoUrl,
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
      coverPhotoKey: d['coverPhotoKey'],
      coverPhotoUrl: d['coverPhotoUrl'],
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
        'coverPhotoKey': coverPhotoKey,
        'coverPhotoUrl': coverPhotoUrl,
      };
}
