import 'package:cloud_firestore/cloud_firestore.dart';
import 'notebook_model.dart';

/// Un tag = l'unité d'organisation des souvenirs (remplace le carnet dans l'UI).
///
/// Le partage se pilote ICI : `sharedWith` / `invitedEmails` d'un tag sont
/// recopiés sur les souvenirs qui le portent (champ `sharedWith` du souvenir),
/// parce que les règles Firestore doivent pouvoir trancher en ne regardant que
/// le document du souvenir.
///
/// `kind` :
///  - `libre`  : tag ordinaire (par défaut) ;
///  - `annee`  / `lieu` : tags posés automatiquement à la création d'un souvenir ;
///  - `enfant` : tag spécial qui porte une date de naissance → débloque la
///    courbe de croissance (héritage des carnets enfant).
class TagModel {
  final String id;
  final String userId;
  final String label;
  final String kind;
  final String color; // hex, ex. '#C4714B'

  // kind == 'enfant'
  final DateTime? birthdate;
  final String? gender; // 'boy' | 'girl'
  final String? companion;
  final String? companionName;

  final List<String> sharedWith; // UIDs des collaborateurs (hors propriétaire)
  final List<String> invitedEmails; // invitations en attente
  final DateTime createdAt;

  const TagModel({
    required this.id,
    required this.userId,
    required this.label,
    this.kind = 'libre',
    this.color = '#C4714B',
    this.birthdate,
    this.gender,
    this.companion,
    this.companionName,
    this.sharedWith = const [],
    this.invitedEmails = const [],
    required this.createdAt,
  });

  bool get isShared => sharedWith.isNotEmpty || invitedEmails.isNotEmpty;
  bool get isChild => kind == 'enfant';
  bool isOwner(String uid) => userId == uid;

  factory TagModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return TagModel(
      id: doc.id,
      userId: d['userId'] ?? '',
      label: d['label'] ?? '',
      kind: d['kind'] ?? 'libre',
      color: d['color'] ?? '#C4714B',
      birthdate: d['birthdate'] != null
          ? (d['birthdate'] as Timestamp).toDate()
          : null,
      gender: d['gender'],
      companion: d['companion'],
      companionName: d['companionName'],
      sharedWith: List<String>.from(d['sharedWith'] ?? []),
      invitedEmails: List<String>.from(d['invitedEmails'] ?? []),
      createdAt: d['createdAt'] != null
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'userId': userId,
        'label': label,
        'kind': kind,
        'color': color,
        if (birthdate != null) 'birthdate': Timestamp.fromDate(birthdate!),
        if (gender != null) 'gender': gender,
        if (companion != null) 'companion': companion,
        if (companionName != null) 'companionName': companionName,
        'sharedWith': sharedWith,
        'invitedEmails': invitedEmails,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  /// Carnet « synthétique » : les écrans hérités (PDF du livre, courbes de
  /// croissance) prennent un [NotebookModel]. Plutôt que de les réécrire, on
  /// leur fabrique un carnet à partir du tag — il n'est jamais persisté.
  NotebookModel asNotebook() => NotebookModel(
        id: id,
        userId: userId,
        type: isChild ? 'enfant' : 'libre',
        title: label,
        coverColor: color,
        companion: companion,
        companionName: companionName,
        birthdate: birthdate,
        gender: gender,
        createdAt: createdAt,
        updatedAt: createdAt,
        sharedWith: sharedWith,
        invitedEmails: invitedEmails,
      );
}
