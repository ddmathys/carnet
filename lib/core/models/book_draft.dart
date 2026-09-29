import 'package:cloud_firestore/cloud_firestore.dart';

/// Texte posé directement SUR une photo du livre, depuis l'éditeur d'aperçu.
/// Propre à UN livre (brouillon), jamais au souvenir : la même photo dans un
/// autre livre part sans texte.
class BookPhotoText {
  /// Longueur max saisissable — au-delà, 3 lignes ne suffisent plus dans une
  /// demi-page (le PDF ne tronque jamais : c'est la saisie qui borne).
  static const maxLength = 120;

  final String text;

  /// Couleur du texte, '#RRGGBB' — une des couleurs de `palette`.
  final String color;

  /// 'top' | 'bottom' — bord de la photo où le texte se pose.
  final String position;

  /// Bandeau plein derrière le texte (lisible sur toute photo, à l'impression).
  final bool background;

  const BookPhotoText({
    required this.text,
    this.color = '#FFFFFF',
    this.position = 'bottom',
    this.background = true,
  });

  /// Couleurs proposées — volontairement peu nombreuses pour garder un livre
  /// harmonieux et un choix simple au doigt.
  static const palette = <String>[
    '#FFFFFF', // blanc
    '#2D2416', // encre
    '#FAF6EE', // crème
    '#C4714B', // terracotta
    '#8FAE7A', // sauge
    '#B94A7A', // framboise
  ];

  Map<String, dynamic> toMap(String photoId) => {
        'photoId': photoId,
        'text': text,
        'color': color,
        'position': position,
        'background': background,
      };

  static BookPhotoText fromMap(Map<String, dynamic> d) => BookPhotoText(
        text: d['text'] as String? ?? '',
        color: d['color'] as String? ?? '#FFFFFF',
        position: d['position'] == 'top' ? 'top' : 'bottom',
        background: d['background'] as bool? ?? true,
      );
}

/// Brouillon de livre, sauvegardé automatiquement pendant l'édition de
/// l'aperçu (collection `bookDrafts`, propriétaire uniquement). Permet de
/// quitter et de reprendre le livre plus tard, dans l'état exact où il était.
///
/// Les photos sont identifiées par leur identifiant STABLE (clé R2 ou URL
/// Firebase legacy — voir `rawMediaIdsOf`), jamais par une URL signée qui
/// expire au bout d'une heure.
class BookDraft {
  final String id;
  final String userId;
  final String? tagId;

  /// Ids demandés à l'ouverture du livre (y compris `growth:<tagId>`), tels
  /// que reçus par BookGenerateScreen.
  final List<String> requestedIds;

  /// Souvenirs effectivement cochés dans le livre.
  final List<String> selectedMemoryIds;
  final String title;
  final String? coverPhotoId;
  final String? backCoverPhotoId;
  final bool excludeCoverPhotoFromBook;
  final List<String> excludedGrowthChildIds;

  /// Photos retirées du livre depuis l'éditeur (le souvenir n'est pas touché).
  final List<String> excludedPhotoIds;
  final Map<String, BookPhotoText> photoTexts;
  final int pageCount;
  final DateTime updatedAt;

  /// 'draft' tant que le livre n'est pas commandé, puis 'ordered'.
  final String status;

  const BookDraft({
    required this.id,
    required this.userId,
    this.tagId,
    this.requestedIds = const [],
    this.selectedMemoryIds = const [],
    this.title = '',
    this.coverPhotoId,
    this.backCoverPhotoId,
    this.excludeCoverPhotoFromBook = false,
    this.excludedGrowthChildIds = const [],
    this.excludedPhotoIds = const [],
    this.photoTexts = const {},
    this.pageCount = 0,
    required this.updatedAt,
    this.status = 'draft',
  });

  static BookDraft fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    // Liste plutôt que map : les identifiants de photos (clés R2, URLs)
    // contiennent des '/' et des '.', mal venus comme noms de champs.
    final texts = <String, BookPhotoText>{};
    for (final raw in (d['photoTexts'] as List<dynamic>? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      final id = m['photoId'] as String?;
      if (id == null || id.isEmpty) continue;
      final t = BookPhotoText.fromMap(m);
      if (t.text.trim().isNotEmpty) texts[id] = t;
    }
    return BookDraft(
      id: doc.id,
      userId: d['userId'] as String? ?? '',
      tagId: d['tagId'] as String?,
      requestedIds: List<String>.from(d['requestedIds'] ?? const []),
      selectedMemoryIds: List<String>.from(d['selectedMemoryIds'] ?? const []),
      title: d['title'] as String? ?? '',
      coverPhotoId: d['coverPhotoId'] as String?,
      backCoverPhotoId: d['backCoverPhotoId'] as String?,
      excludeCoverPhotoFromBook:
          d['excludeCoverPhotoFromBook'] as bool? ?? false,
      excludedGrowthChildIds:
          List<String>.from(d['excludedGrowthChildIds'] ?? const []),
      excludedPhotoIds: List<String>.from(d['excludedPhotoIds'] ?? const []),
      photoTexts: texts,
      pageCount: (d['pageCount'] as num?)?.toInt() ?? 0,
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      status: d['status'] as String? ?? 'draft',
    );
  }

  Map<String, dynamic> toMap() => {
        'userId': userId,
        'tagId': tagId,
        'requestedIds': requestedIds,
        'selectedMemoryIds': selectedMemoryIds,
        'title': title,
        'coverPhotoId': coverPhotoId,
        'backCoverPhotoId': backCoverPhotoId,
        'excludeCoverPhotoFromBook': excludeCoverPhotoFromBook,
        'excludedGrowthChildIds': excludedGrowthChildIds,
        'excludedPhotoIds': excludedPhotoIds,
        'photoTexts': [
          for (final e in photoTexts.entries) e.value.toMap(e.key),
        ],
        'pageCount': pageCount,
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
      };
}
