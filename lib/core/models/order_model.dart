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
  final int? pageCount; // nombre de pages du PDF (pour Gelato)
  final String? pdfUrl;
  final String? gelatoOrderId;
  // 'draft' (brouillon, à confirmer dans le dashboard Gelato) |
  // 'pending' (renvoi direct en cours, résultat pas encore connu) |
  // 'accepted' | 'refused' (résultat réel, connu via /api/gelato/status ou
  // le cron de poll — jamais via la création elle-même) | 'error' (échec
  // synchrone à l'envoi) | null (jamais envoyé).
  final String? gelatoStatus;
  final String? gelatoError;
  final String? refusalReason;
  final String? refusalReasonCode;
  final int gelatoRetryCount;

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
    this.gelatoOrderId,
    this.gelatoStatus,
    this.gelatoError,
    this.refusalReason,
    this.refusalReasonCode,
    this.gelatoRetryCount = 0,
  });

  String get fullName => '$firstName $lastName';

  String get fullAddress => '$street, $npa $city, $country';

  String get statusLabel => _statusLabels[status] ?? status;

  String get statusEmoji => _statusEmojis[status] ?? '📦';

  static const _statusLabels = {
    'received':  'Commande reçue',
    'validated': 'Validée',
    'printing':  'En impression',
    'ready':     'À envoyer',
    'invoiced':  'À payer',
    'paid':      'Payée',
  };

  static const _statusEmojis = {
    'received':  '📬',
    'validated': '✅',
    'printing':  '🖨️',
    'ready':     '📦',
    'invoiced':  '🧾',
    'paid':      '💚',
  };

  // Ordered list for timeline. Le paiement déclenche la commande → il vient
  // AVANT l'impression et l'envoi.
  static const statusFlow = [
    'received',
    'validated',
    'invoiced',
    'paid',
    'printing',
    'ready',
  ];

  int get statusIndex => statusFlow.indexOf(status);

  bool get gelatoWasRefused => gelatoStatus == 'refused';
  int get gelatoRetriesLeft => (3 - gelatoRetryCount).clamp(0, 3);
  bool get canRetryGelato => gelatoWasRefused && gelatoRetriesLeft > 0;

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
      gelatoOrderId: d['gelatoOrderId'],
      gelatoStatus: d['gelatoStatus'],
      gelatoError: d['gelatoError'],
      refusalReason: d['refusalReason'],
      refusalReasonCode: d['refusalReasonCode'],
      gelatoRetryCount: (d['gelatoRetryCount'] as num?)?.toInt() ?? 0,
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
