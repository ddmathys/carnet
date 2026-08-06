import 'package:cloud_firestore/cloud_firestore.dart';

class OrderModel {
  final String id;
  final String userId;
  final String userEmail;
  final String bookTitle;
  final String coverType; // 'soft' | 'hard'
  final double price;
  final String firstName;
  final String lastName;
  final String street;
  final String city;
  final String npa;
  final String country;
  final String status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String notebookId;
  final String? adminNote;
  final int memoryCount;
  final int? pageCount; // nombre de pages du PDF (imprimeur)
  final String? pdfUrl;
  final String? prodigiOrderId;
  // 'pending' (envoyée, résultat définitif pas encore connu) | 'accepted'
  // (en production/expédiée) | 'error' (refusée ou échec technique) | null
  // (jamais envoyée à l'impression).
  final String? prodigiStatus;
  final String? prodigiError;
  // Nombre de renvois admin après une erreur (voir _buildPrintSection dans
  // admin_orders_screen.dart) — plafonné à 3, appliqué aussi côté backend
  // (backend/api/prodigi/[action].ts) pour ne pas dépendre uniquement du
  // client.
  final int prodigiRetryCount;

  const OrderModel({
    required this.id,
    required this.userId,
    required this.userEmail,
    required this.bookTitle,
    required this.coverType,
    required this.price,
    required this.firstName,
    required this.lastName,
    required this.street,
    required this.city,
    required this.npa,
    required this.country,
    required this.status,
    required this.createdAt,
    this.updatedAt,
    required this.notebookId,
    this.adminNote,
    required this.memoryCount,
    this.pageCount,
    this.pdfUrl,
    this.prodigiOrderId,
    this.prodigiStatus,
    this.prodigiError,
    this.prodigiRetryCount = 0,
  });

  String get fullName => '$firstName $lastName';

  String get fullAddress => '$street, $npa $city, $country';

  String get statusLabel => _statusLabels[status] ?? status;

  String get statusEmoji => _statusEmojis[status] ?? '📦';

  static const _statusLabels = {
    'received': 'Commande reçue',
    'paid':     'Payée',
    'shipped':  'Livrée',
  };

  static const _statusEmojis = {
    'received': '📬',
    'paid':     '💚',
    'shipped':  '📦',
  };

  // Ordered list pour le suivi client : volontairement réduit à 3 étapes.
  // Le paiement se fait hors app (l'équipe recontacte séparément) et
  // déclenche l'impression + l'envoi, regroupés ici sous "Livrée".
  static const statusFlow = [
    'received',
    'paid',
    'shipped',
  ];

  int get statusIndex => statusFlow.indexOf(status);

  bool get prodigiHasError => prodigiStatus == 'error';
  int get prodigiRetriesLeft => (3 - prodigiRetryCount).clamp(0, 3);
  bool get canRetryPrint => prodigiHasError && prodigiRetriesLeft > 0;

  factory OrderModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return OrderModel(
      id: doc.id,
      userId: d['userId'] ?? '',
      userEmail: d['userEmail'] ?? '',
      bookTitle: d['bookTitle'] ?? '',
      coverType: d['coverType'] ?? 'soft',
      price: (d['price'] as num?)?.toDouble() ?? 0,
      firstName: d['firstName'] ?? '',
      lastName: d['lastName'] ?? '',
      street: d['street'] ?? '',
      city: d['city'] ?? '',
      npa: d['npa'] ?? '',
      country: d['country'] ?? 'Suisse',
      status: d['status'] ?? 'received',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
      notebookId: d['notebookId'] ?? '',
      adminNote: d['adminNote'],
      memoryCount: (d['memoryCount'] as num?)?.toInt() ?? 0,
      pageCount: (d['pageCount'] as num?)?.toInt(),
      pdfUrl: d['pdfUrl'],
      prodigiOrderId: d['prodigiOrderId'],
      prodigiStatus: d['prodigiStatus'],
      prodigiError: d['prodigiError'],
      prodigiRetryCount: (d['prodigiRetryCount'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toFirestore() => {
    'userId': userId,
    'userEmail': userEmail,
    'bookTitle': bookTitle,
    'coverType': coverType,
    'price': price,
    'firstName': firstName,
    'lastName': lastName,
    'street': street,
    'city': city,
    'npa': npa,
    'country': country,
    'status': status,
    'createdAt': Timestamp.fromDate(createdAt),
    'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
    'notebookId': notebookId,
    'adminNote': adminNote,
    'memoryCount': memoryCount,
    'pageCount': pageCount,
    'pdfUrl': pdfUrl,
  };
}
