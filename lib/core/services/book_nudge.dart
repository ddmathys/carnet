import 'package:intl/intl.dart';

import '../models/memory_model.dart';
import '../models/tag_model.dart';

/// Suggestion de livre affichée sur l'accueil (21.10.26).
///
/// Sans relance, on accumule des souvenirs et on ne commande jamais : la marge
/// se fait pourtant uniquement sur l'imprimé. Ces suggestions restent DANS
/// l'app — aucun e-mail, aucune notification —, donc sans consentement
/// marketing à recueillir.
///
/// Une seule à la fois, la plus pertinente (voir [BookNudge.pick]). « Plus
/// tard » la met en sourdine via son [id] ; un id porte l'année ou le palier
/// atteint, pour qu'une suggestion revienne quand la situation a vraiment
/// changé (anniversaire suivant, 40 souvenirs de plus…).
class BookNudge {
  final String id;
  final String emoji;
  final String title;
  final String body;

  /// Tag pré-sélectionné dans le choix des souvenirs (null = tous).
  final String? tagId;

  /// Le bouton principal est « L'offrir » plutôt que « Créer le livre » :
  /// souvenirs partagés par quelqu'un d'autre (un grand-parent offre plus
  /// souvent qu'il ne commande pour lui).
  final bool giftFirst;

  const BookNudge({
    required this.id,
    required this.emoji,
    required this.title,
    required this.body,
    this.tagId,
    this.giftFirst = false,
  });

  /// Souvenirs nécessaires pour suggérer un livre (palier).
  static const int threshold = 40;

  /// Fenêtre d'avance sur un anniversaire.
  static const int birthdayDays = 30;

  /// Souvenirs minimum autour d'une personne pour suggérer SON livre.
  static const int minForPerson = 12;

  /// Souvenirs de l'année minimum pour le livre de fin d'année.
  static const int minForYear = 20;

  /// Choisit la suggestion du moment, ou null.
  ///
  /// [memories] : tous les souvenirs visibles (les miens et ceux qu'on me
  /// partage). [ownTags] : mes tags. [sharedTags] : ceux qu'on me partage.
  /// [lastBookOrderAt] : date de ma dernière commande de livre.
  static BookNudge? pick({
    required String uid,
    required List<MemoryModel> memories,
    required List<TagModel> ownTags,
    required List<TagModel> sharedTags,
    required DateTime now,
    DateTime? lastBookOrderAt,
    Set<String> dismissed = const {},
  }) {
    final real = memories.where((m) => m.type != 'taille_poids').toList();
    int countTag(String tagId) =>
        real.where((m) => m.tagIds.contains(tagId)).length;

    final candidates = <BookNudge>[];

    // 1. Anniversaire d'un enfant dans les 30 jours.
    for (final t in [...ownTags, ...sharedTags]) {
      final birth = t.birthdate;
      if (!t.isChild || birth == null) continue;
      final next = _nextBirthday(birth, now);
      final days = DateTime(next.year, next.month, next.day)
          .difference(DateTime(now.year, now.month, now.day))
          .inDays;
      if (days < 0 || days > birthdayDays) continue;
      final n = countTag(t.id);
      if (n < minForPerson) continue;
      final age = next.year - birth.year;
      final mine = t.userId == uid;
      candidates.add(BookNudge(
        id: 'birthday:${t.id}:${next.year}',
        emoji: '🎂',
        title: days == 0
            ? '${t.label} fête ses $age ans aujourd\'hui'
            : '${t.label} fête ses $age ans le '
                '${DateFormat('d MMMM', 'fr').format(next)}',
        body: '$n souvenirs l\'attendent. Son année en livre, '
            '${mine ? 'pour toi ou à offrir' : 'à offrir à toute la famille'}.',
        tagId: t.id,
        giftFirst: !mine,
      ));
    }

    // 2. Le livre de l'année, du 1er novembre au 15 décembre.
    final inSeason = (now.month == 11) || (now.month == 12 && now.day <= 15);
    if (inSeason) {
      final n = real.where((m) => m.date.year == now.year).length;
      if (n >= minForYear) {
        candidates.add(BookNudge(
          id: 'year:${now.year}',
          emoji: '🎄',
          title: 'Le livre de ${now.year}',
          body: '$n souvenirs cette année. Pour Noël, commande tôt : '
              'l\'impression et la livraison prennent du temps.',
        ));
      }
    }

    // 3. Souvenirs qu'on me partage (je suis invité sur le tag de quelqu'un).
    for (final t in sharedTags) {
      if (t.userId == uid) continue;
      final n = countTag(t.id);
      if (n < minForPerson) continue;
      candidates.add(BookNudge(
        id: 'shared:${t.id}:${n ~/ threshold}',
        emoji: '🎁',
        title: 'Les souvenirs de ${t.label} en livre',
        body: '$n souvenirs partagés avec toi. Un livre pour toi, ou à offrir '
            '— il part directement chez la personne, avec ton mot en première '
            'page.',
        tagId: t.id,
        giftFirst: true,
      ));
    }

    // 4. Assez de souvenirs depuis le dernier livre.
    final mine = real.where((m) => m.userId == uid);
    final since = lastBookOrderAt == null
        ? mine.length
        : mine.where((m) => m.createdAt.isAfter(lastBookOrderAt)).length;
    if (since >= threshold) {
      candidates.add(BookNudge(
        id: 'threshold:${lastBookOrderAt?.millisecondsSinceEpoch ?? 0}:'
            '${since ~/ threshold}',
        emoji: '📖',
        title: lastBookOrderAt == null
            ? 'Assez de souvenirs pour un beau livre'
            : '$since souvenirs depuis ton dernier livre',
        body: lastBookOrderAt == null
            ? '$since souvenirs : de quoi remplir un livre. L\'aperçu est '
                'gratuit, tu ne paies qu\'à la commande.'
            : 'De quoi faire le tome suivant. L\'aperçu est gratuit, tu ne '
                'paies qu\'à la commande.',
      ));
    }

    for (final c in candidates) {
      if (!dismissed.contains(c.id)) return c;
    }
    return null;
  }

  static DateTime _nextBirthday(DateTime birth, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    // Un 29 février tombe le 1er mars les années non bissextiles (DateTime
    // normalise tout seul).
    var next = DateTime(now.year, birth.month, birth.day);
    if (next.isBefore(today)) next = DateTime(now.year + 1, birth.month, birth.day);
    return next;
  }
}
