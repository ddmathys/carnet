import 'package:cloud_firestore/cloud_firestore.dart';

/// Texte posé directement SUR une photo du livre, depuis l'éditeur d'aperçu.
/// Propre à UN livre (brouillon), jamais au souvenir : la même photo dans un
/// autre livre part sans texte.
class BookPhotoText {
  /// Longueur max saisissable (un vrai commentaire, pas juste une légende) —
  /// le PDF ne tronque jamais : c'est la saisie qui borne, et l'éditeur
  /// montre exactement ce qui tiendra puisqu'il rend le texte comme le PDF.
  static const maxLength = 200;

  /// Nombre de lignes de l'encadré, le même dans l'éditeur et dans le PDF.
  static const maxLines = 6;

  final String text;

  /// Couleur du texte, '#RRGGBB' — une des couleurs de `palette`.
  final String color;

  /// Ancienne position fixe ('top' | 'bottom'), utilisée seulement quand
  /// `x`/`y` sont absents (textes créés avant l'encadré déplaçable).
  final String position;

  /// Encadré blanc derrière le texte (lisible sur toute photo, à l'impression).
  final bool background;

  /// Position libre de l'encadré dans la photo, 0..1 sur chaque axe
  /// (0 = collé à gauche/en haut de la zone de sécurité, 1 = à droite/en
  /// bas) — l'encadré reste TOUJOURS entier dans la photo, quelle que soit
  /// sa taille (même logique d'alignement dans l'éditeur et dans le PDF).
  final double? x;
  final double? y;

  /// Police du texte : une des clés de `fonts` ('serif' | 'sans' | 'script').
  final String font;

  /// Taille choisie au doigt, 1 = taille de référence
  /// (`BookPdfService.photoTextFontSize`). Bornée par minScale/maxScale.
  final double scale;

  const BookPhotoText({
    required this.text,
    this.color = '#2D2416',
    this.position = 'bottom',
    this.background = true,
    this.x,
    this.y,
    this.font = fontSerif,
    this.scale = 1,
  });

  BookPhotoText copyWith({
    String? text,
    String? color,
    bool? background,
    double? x,
    double? y,
    String? font,
    double? scale,
  }) =>
      BookPhotoText(
        text: text ?? this.text,
        color: color ?? this.color,
        position: position,
        background: background ?? this.background,
        x: x ?? this.x,
        y: y ?? this.y,
        font: font ?? this.font,
        scale: scale ?? this.scale,
      );

  // ── Polices ───────────────────────────────────────────────────────────────
  // Les trois .ttf déjà embarqués (pubspec.yaml) : l'éditeur les applique via
  // leur famille Flutter, le PDF charge le MÊME fichier — ce qui est à
  // l'écran est donc ce qui s'imprime.
  static const fontSerif = 'serif';
  static const fontSans = 'sans';
  static const fontScript = 'script';
  static const fonts = <String>[fontSerif, fontSans, fontScript];

  static String normalizeFont(String? font) =>
      fonts.contains(font) ? font! : fontSerif;

  /// Famille Flutter (déclarée dans pubspec.yaml).
  static String familyOf(String font) => switch (normalizeFont(font)) {
        fontSans => 'Outfit',
        fontScript => 'Caveat',
        _ => 'Fraunces',
      };

  /// Fichier de police chargé par le PDF — le même que la famille ci-dessus.
  static String assetOf(String font) => switch (normalizeFont(font)) {
        fontSans => 'assets/fonts/Outfit.ttf',
        fontScript => 'assets/fonts/Caveat.ttf',
        _ => 'assets/fonts/Fraunces.ttf',
      };

  static String labelOf(String font) => switch (normalizeFont(font)) {
        fontSans => 'Moderne',
        fontScript => 'Manuscrit',
        _ => 'Classique',
      };

  /// Correction de taille propre à chaque police : à taille de police égale,
  /// Caveat (manuscrite) écrit beaucoup plus petit que Fraunces, Outfit un
  /// poil plus petit. Sans ça, changer de police changerait la taille
  /// apparente du texte.
  static double metricOf(String font) => switch (normalizeFont(font)) {
        fontSans => 0.97,
        fontScript => 1.45,
        _ => 1.0,
      };

  static const minScale = 0.7;
  static const maxScale = 2.2;

  static double normalizeScale(double? scale) =>
      (scale ?? 1).clamp(minScale, maxScale);

  /// Multiplicateur appliqué à la taille de référence ET aux marges de
  /// l'encadré, côté éditeur comme côté PDF.
  double get sizeFactor => metricOf(font) * normalizeScale(scale);

  /// Marges de l'encadré : elles suivent la taille du texte, mais moins vite
  /// (un gros texte n'a pas besoin d'un cadre deux fois plus épais).
  double get padFactor => 1 + (normalizeScale(scale) - 1) * 0.5;

  /// Combien de lignes tiennent dans la hauteur disponible de la case
  /// (en points PDF), jamais plus que `maxLines`.
  ///
  /// Sans cette borne, un texte écrit en grand débordait de sa case à
  /// l'impression (le PDF, lui, ne rogne pas) alors que l'écran le coupait :
  /// l'aperçu aurait menti. Les deux côtés appellent donc ce même calcul.
  int lineCapacity({
    required double availableHeight,
    required double baseFontSize,
    required double basePadV,
  }) {
    final line = baseFontSize * sizeFactor * 1.25 + 2;
    final inner = availableHeight - (background ? 2 * basePadV * padFactor : 0);
    if (line <= 0 || inner <= line) return 1;
    return (inner / line).floor().clamp(1, maxLines);
  }

  /// Position par défaut d'un nouveau texte : centré, en bas.
  static const defaultX = 0.5;
  static const defaultY = 0.92;

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
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        'font': font,
        'scale': scale,
      };

  static BookPhotoText fromMap(Map<String, dynamic> d) => BookPhotoText(
        text: d['text'] as String? ?? '',
        color: d['color'] as String? ?? '#FFFFFF',
        position: d['position'] == 'top' ? 'top' : 'bottom',
        background: d['background'] as bool? ?? true,
        x: (d['x'] as num?)?.toDouble(),
        y: (d['y'] as num?)?.toDouble(),
        font: normalizeFont(d['font'] as String?),
        scale: normalizeScale((d['scale'] as num?)?.toDouble()),
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
