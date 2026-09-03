import 'package:cloud_firestore/cloud_firestore.dart';

/// Une activité (ajout de médias) sur un souvenir partagé, à faire valider
/// (accusé de lecture) par chaque destinataire indépendamment — voir
/// [[project_bloom]] / audit du 03.09.26 : Karin ajoutait des photos sans
/// jamais savoir si c'était bien enregistré, et David n'était pas prévenu.
class MemoryActivityModel {
  final String id;
  final String memoryId;
  final String memoryTitle;
  /// 'created' (nouveau souvenir sur un tag partagé) ou 'edited' (médias
  /// ajoutés à un souvenir existant).
  final String kind;
  final String actorUid;
  final String actorLabel;
  final int photosAdded;
  final int videosAdded;
  /// Qui doit voir cette activité — propriétaire + collaborateurs du
  /// souvenir AU MOMENT de l'action (figé, ne suit pas les partages
  /// ultérieurs, comme les autres snapshots de ce genre dans l'app).
  final List<String> recipients;
  /// Uids ayant déjà "validé" (fermé) la notification — par destinataire,
  /// pas global : que Karin la ferme ne la fait pas disparaître pour David.
  final List<String> seenBy;
  final DateTime createdAt;

  const MemoryActivityModel({
    required this.id,
    required this.memoryId,
    required this.memoryTitle,
    required this.kind,
    required this.actorUid,
    required this.actorLabel,
    required this.photosAdded,
    required this.videosAdded,
    required this.recipients,
    required this.seenBy,
    required this.createdAt,
  });

  bool get isCreated => kind == 'created';

  factory MemoryActivityModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return MemoryActivityModel(
      id: doc.id,
      memoryId: d['memoryId'] ?? '',
      memoryTitle: d['memoryTitle'] ?? '',
      kind: d['kind'] ?? 'edited',
      actorUid: d['actorUid'] ?? '',
      actorLabel: d['actorLabel'] ?? '',
      photosAdded: (d['photosAdded'] as num?)?.toInt() ?? 0,
      videosAdded: (d['videosAdded'] as num?)?.toInt() ?? 0,
      recipients: List<String>.from(d['recipients'] ?? const []),
      seenBy: List<String>.from(d['seenBy'] ?? const []),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
