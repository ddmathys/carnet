import 'package:cloud_firestore/cloud_firestore.dart';

/// Un colis tel que remonté par Prodigi (`prodigiShipments` sur la commande).
/// Une commande peut en avoir plusieurs (livre et poster fabriqués dans deux
/// ateliers différents partent séparément) — d'où la liste plutôt qu'un seul
/// numéro de suivi.
class OrderShipment {
  final String? id;
  final String? carrier;
  final String? service;
  final String? trackingNumber;
  final String? trackingUrl;
  final DateTime? dispatchedAt;

  /// Pays de l'atelier d'où part le colis (ISO 2 lettres) — Prodigi répartit
  /// la fabrication entre plusieurs pays selon le produit.
  final String? fromCountry;

  const OrderShipment({
    this.id,
    this.carrier,
    this.service,
    this.trackingNumber,
    this.trackingUrl,
    this.dispatchedAt,
    this.fromCountry,
  });

  factory OrderShipment.fromMap(Map<String, dynamic> m) {
    final rawDate = m['dispatchedAt'];
    return OrderShipment(
      id: m['id'] as String?,
      carrier: m['carrier'] as String?,
      service: m['service'] as String?,
      trackingNumber: m['trackingNumber'] as String?,
      trackingUrl: m['trackingUrl'] as String?,
      // Le backend écrit une chaîne ISO (telle que reçue de Prodigi) ; on
      // accepte aussi un Timestamp au cas où le champ serait normalisé plus
      // tard côté serveur.
      dispatchedAt: rawDate is Timestamp
          ? rawDate.toDate()
          : rawDate is String
              ? DateTime.tryParse(rawDate)
              : null,
      fromCountry: m['fromCountry'] as String?,
    );
  }

  bool get isDispatched => dispatchedAt != null || trackingNumber != null;

  /// Nom lisible du pays d'expédition — les seuls ateliers Prodigi utilisés
  /// aujourd'hui ; on retombe sur le code ISO brut pour tout autre pays.
  String? get fromCountryLabel => switch (fromCountry?.toUpperCase()) {
        'GB' => 'Royaume-Uni',
        'NL' => 'Pays-Bas',
        'DE' => 'Allemagne',
        'FR' => 'France',
        'IT' => 'Italie',
        'ES' => 'Espagne',
        'US' => 'États-Unis',
        'CH' => 'Suisse',
        null => null,
        _ => fromCountry,
      };
}

class OrderModel {
  final String id;
  final String userId;
  final String userEmail;
  // Titre affiché (liste admin, PDF téléchargé, email) : le titre du livre
  // pour un livre, un libellé généré ("Poster A2") pour un poster — jamais
  // saisi par l'utilisateur pour ce second produit. Nom historique conservé
  // pour ne pas toucher tous les affichages existants.
  final String bookTitle;
  final String coverType; // 'soft' | 'hard' — vide pour un poster
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
  // Étape d'impression, telle que relue chez Prodigi (voir
  // backend/lib/prodigi.ts) :
  //   'pending'      — envoyée, Prodigi prépare le fichier / choisit l'atelier
  //   'inProduction' — en fabrication
  //   'shipped'      — au moins un colis parti (suivi disponible)
  //   'error'        — refusée, annulée, ou échec technique
  //   null           — jamais envoyée à l'impression
  // ⚠️ 'accepted' est une valeur HISTORIQUE (l'ancien backend confondait
  // production et expédition) : plus jamais écrite, mais encore portée par les
  // commandes d'avant ce changement — traitée ici comme 'inProduction'.
  final String? prodigiStatus;
  final String? prodigiError;
  /// `order.status.stage` brut chez Prodigi — affiché en console admin.
  final String? prodigiStage;
  /// Dernière relecture du statut chez Prodigi (cron quotidien ou manuelle).
  final DateTime? prodigiLastCheckedAt;
  /// Colis expédiés par Prodigi, avec leurs numéros de suivi.
  final List<OrderShipment> shipments;
  /// Date d'expédition du premier colis, telle que datée par Prodigi.
  final DateTime? shippedAt;
  /// Montant réellement facturé par Prodigi (article + livraison + taxes),
  /// dans sa devise — sert à repérer un écart avec le prix affiché au client.
  final double? prodigiChargedTotal;
  final String? prodigiChargedCurrency;
  // Nombre de renvois admin après une erreur (voir _buildPrintSection dans
  // admin_orders_screen.dart) — plafonné à 3, appliqué aussi côté backend
  // (backend/api/prodigi/[action].ts) pour ne pas dépendre uniquement du
  // client.
  final int prodigiRetryCount;

  // ── Discriminant produit ──────────────────────────────────────────────
  // 'book' (défaut, rétrocompatible avec toutes les commandes existantes)
  // ou 'poster'. Les champs `poster*` ci-dessous sont null pour un livre.
  final String productType;
  final String? posterSku;
  final String? posterSize; // 'A4' | 'A3' | 'A2' | 'A1' | 'A0'
  final String? posterOrientation; // 'portrait' | 'landscape'
  final String? posterHangerColor; // 'black' | 'natural' | 'white'
  final String? posterCaption;
  // Souvenirs dont les vidéos alimentent le QR imprimé sur le poster (le QR
  // pointe en réalité vers un `posterReels/{id}` distinct, créé avant la
  // commande — voir poster_generate_screen.dart — ce champ est gardé pour
  // affichage/traçabilité admin).
  final List<String>? posterMemoryIds;
  // Vignette du tirage (photo « en vedette », ou 1ʳᵉ photo à défaut) —
  // affichage seul, sans usage impression. Null pour un livre. Clé R2 :
  // résolue en URL signée à l'affichage — jamais une URL signée stockée
  // telle quelle, elle expire au bout d'1h (voir generated_book_model.dart
  // pour la même remarque côté livre). `posterPhotoUrl` reste pour les
  // photos Firebase héritées (URL permanente).
  final String? posterPhotoKey;
  final String? posterPhotoUrl;

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
    this.prodigiStage,
    this.prodigiLastCheckedAt,
    this.shipments = const [],
    this.shippedAt,
    this.prodigiChargedTotal,
    this.prodigiChargedCurrency,
    this.prodigiRetryCount = 0,
    this.productType = 'book',
    this.posterSku,
    this.posterSize,
    this.posterOrientation,
    this.posterHangerColor,
    this.posterCaption,
    this.posterMemoryIds,
    this.posterPhotoKey,
    this.posterPhotoUrl,
  });

  bool get isPoster => productType == 'poster';

  String get fullName => '$firstName $lastName';

  String get fullAddress => '$street, $npa $city, $country';

  String get statusLabel => statusLabelFor(status);

  String get statusEmoji => statusEmojiFor(status);

  // Versions statiques : le suivi affiche TOUTES les étapes, pas seulement
  // celle en cours, et n'a donc pas d'OrderModel sous la main pour chacune.
  static String statusLabelFor(String status) => _statusLabels[status] ?? status;

  static String statusEmojiFor(String status) => _statusEmojis[status] ?? '📦';

  static String? statusHintFor(String status) => statusHints[status];

  // « Expédiée » et non « Livrée » : Prodigi ne signale que le départ du colis
  // (`dispatchDate`), jamais la remise au destinataire. C'est le suivi
  // transporteur, lié depuis l'écran de commande, qui dit si c'est arrivé.
  static const _statusLabels = {
    'received': 'Commande reçue',
    'paid':     'Payée',
    'shipped':  'Expédiée',
  };

  static const _statusEmojis = {
    'received': '📬',
    'paid':     '💚',
    'shipped':  '📦',
  };

  /// Sous-titre de chaque étape du suivi client — dit ce qu'il se passe
  /// vraiment à ce moment-là plutôt que de laisser deviner.
  static const statusHints = {
    'received': 'On a reçu ta commande, en attente du paiement.',
    'paid':     'Paiement confirmé — direction l\'atelier d\'impression.',
    'shipped':  'Le colis a quitté l\'atelier, suis-le avec le numéro ci-dessous.',
  };

  // Ordered list pour le suivi client : volontairement réduit à 3 étapes.
  // Le paiement se fait hors app (l'équipe recontacte séparément) et
  // déclenche l'impression, puis l'expédition ("Expédiée"), désormais
  // avancée automatiquement dès que Prodigi signale un colis parti
  // (voir refreshProdigiOrderStatus dans backend/lib/prodigi.ts).
  static const statusFlow = [
    'received',
    'paid',
    'shipped',
  ];

  int get statusIndex => statusFlow.indexOf(status);

  bool get prodigiHasError => prodigiStatus == 'error';
  int get prodigiRetriesLeft => (3 - prodigiRetryCount).clamp(0, 3);
  bool get canRetryPrint => prodigiHasError && prodigiRetriesLeft > 0;

  // ── Étape d'impression ───────────────────────────────────────────────────

  /// Statut d'impression normalisé : replie la valeur historique 'accepted'
  /// sur 'inProduction', pour que le reste de l'app n'ait qu'un seul jeu de
  /// valeurs à connaître.
  String? get printStage =>
      prodigiStatus == 'accepted' ? 'inProduction' : prodigiStatus;

  /// L'impression est-elle encore en cours chez Prodigi ? (= vaut la peine de
  /// re-demander le statut au backend)
  bool get isPrintInProgress =>
      printStage == 'pending' || printStage == 'inProduction';

  /// Libellé client de l'étape d'impression, null quand il n'y a rien à dire.
  String? get printStageLabel => switch (printStage) {
        'pending' => 'Préparation chez l\'imprimeur',
        'inProduction' => 'En cours de fabrication',
        'shipped' => 'Expédiée',
        'error' => 'Problème à l\'impression',
        _ => null,
      };

  /// Colis effectivement partis (ceux qui ont une date d'envoi ou un suivi).
  List<OrderShipment> get dispatchedShipments =>
      shipments.where((s) => s.isDispatched).toList();

  /// Colis principal — celui dont le numéro de suivi est mis en avant.
  OrderShipment? get primaryShipment =>
      dispatchedShipments.isNotEmpty ? dispatchedShipments.first : null;

  bool get hasTracking => primaryShipment?.trackingNumber != null;

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
      prodigiStage: d['prodigiStage'],
      prodigiLastCheckedAt: (d['prodigiLastCheckedAt'] as Timestamp?)?.toDate(),
      shipments: (d['prodigiShipments'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map(OrderShipment.fromMap)
              .toList() ??
          const [],
      shippedAt: (d['shippedAt'] as Timestamp?)?.toDate(),
      prodigiChargedTotal: (d['prodigiChargedTotal'] as num?)?.toDouble(),
      prodigiChargedCurrency: d['prodigiChargedCurrency'],
      prodigiRetryCount: (d['prodigiRetryCount'] as num?)?.toInt() ?? 0,
      productType: d['productType'] ?? 'book',
      posterSku: d['posterSku'],
      posterSize: d['posterSize'],
      posterOrientation: d['posterOrientation'],
      posterHangerColor: d['posterHangerColor'],
      posterCaption: d['posterCaption'],
      posterMemoryIds: (d['posterMemoryIds'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      posterPhotoKey: d['posterPhotoKey'],
      posterPhotoUrl: d['posterPhotoUrl'],
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
    'productType': productType,
    'posterSku': posterSku,
    'posterSize': posterSize,
    'posterOrientation': posterOrientation,
    'posterHangerColor': posterHangerColor,
    'posterCaption': posterCaption,
    'posterMemoryIds': posterMemoryIds,
    'posterPhotoKey': posterPhotoKey,
    'posterPhotoUrl': posterPhotoUrl,
  };
}
