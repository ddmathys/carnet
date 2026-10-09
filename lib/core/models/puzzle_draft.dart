import 'package:cloud_firestore/cloud_firestore.dart';

/// Puzzle commencé mais pas encore commandé (collection `puzzleDrafts`,
/// propriétaire uniquement) — même rôle que [BookDraft] pour les livres :
/// quitter l'app, recevoir un appel ou se tromper de bouton ne doit pas faire
/// perdre la photo choisie et la taille réglée.
///
/// La photo n'est PAS stockée dans le document : elle est envoyée sur R2 dès
/// qu'elle est choisie (le même envoi que celui de la commande, fait plus tôt)
/// et seule son URL permanente est gardée ici. C'est ce qui permet de
/// reprendre le puzzle depuis un autre téléphone — et, une fois commandé, de
/// ne pas renvoyer les 5 Mo une deuxième fois.
class PuzzleDraft {
  final String id;
  final String userId;

  /// URL permanente de la photo d'impression déjà envoyée (backend → R2).
  final String photoUrl;

  /// Taille choisie ('252' | '500' | '1000'), telle que PuzzlePricing.
  final String size;

  /// Dimensions de la photo, pour réafficher le contrôle de résolution sans
  /// attendre le retéléchargement.
  final int photoW;
  final int photoH;

  /// Souvenir d'origine, quand le puzzle en vient (QR vidéo sur le
  /// couvercle). null pour une photo prise directement dans la galerie.
  final String? memoryId;
  final int? photoIndex;

  final DateTime updatedAt;

  /// 'draft' tant que le puzzle n'est pas commandé, puis 'ordered'.
  final String status;

  const PuzzleDraft({
    required this.id,
    required this.userId,
    required this.photoUrl,
    required this.size,
    this.photoW = 0,
    this.photoH = 0,
    this.memoryId,
    this.photoIndex,
    required this.updatedAt,
    this.status = 'draft',
  });

  bool get fromMemory => memoryId != null && memoryId!.isNotEmpty;

  ({int w, int h})? get dims =>
      photoW > 0 && photoH > 0 ? (w: photoW, h: photoH) : null;

  static PuzzleDraft fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return PuzzleDraft(
      id: doc.id,
      userId: d['userId'] as String? ?? '',
      photoUrl: d['photoUrl'] as String? ?? '',
      size: d['size'] as String? ?? '',
      photoW: (d['photoW'] as num?)?.toInt() ?? 0,
      photoH: (d['photoH'] as num?)?.toInt() ?? 0,
      memoryId: d['memoryId'] as String?,
      photoIndex: (d['photoIndex'] as num?)?.toInt(),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      status: d['status'] as String? ?? 'draft',
    );
  }

  Map<String, dynamic> toMap() => {
        'userId': userId,
        'photoUrl': photoUrl,
        'size': size,
        'photoW': photoW,
        'photoH': photoH,
        'memoryId': memoryId,
        'photoIndex': photoIndex,
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
      };
}
