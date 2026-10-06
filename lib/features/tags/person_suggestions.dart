import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';

/// Une personne proposée pour le souvenir en cours de saisie, avec la raison
/// qui l'a fait remonter (affichée sous la pastille : la suggestion doit être
/// explicable, sinon elle n'est pas validable en confiance).
class PersonSuggestion {
  final TagModel tag;
  final String reason;
  final double score;

  const PersonSuggestion(
      {required this.tag, required this.reason, required this.score});
}

/// Qui proposer d'ajouter à ce souvenir, **sans regarder les photos**.
///
/// Aucune reconnaissance de visage, aucune analyse d'image, rien qui sorte du
/// téléphone : on ne devine pas qui EST sur la photo, on rappelle qui
/// l'utilisateur tague D'HABITUDE dans ce contexte-là (même lieu, même
/// période, ses derniers souvenirs). C'est un choix délibéré et pas seulement
/// une question de coût : dans Carnet, un tag de personne peut être partagé, et
/// `sharedWith` est recopié sur le souvenir — c'est lui que lisent les règles
/// Firestore. Une suggestion fausse mais acceptée d'un geste ouvrirait donc
/// l'accès au souvenir à quelqu'un. D'où deux garde-fous : rien n'est posé sans
/// un tap de validation, et une personne qui n'a jamais été taguée dans ce
/// contexte n'est jamais proposée.
///
/// Les quatre signaux, du plus parlant au moins parlant :
///  1. le LIEU — qui accompagne l'utilisateur à cet endroit ;
///  2. la PÉRIODE — les souvenirs d'un même voyage/événement se suivent ;
///  3. la RÉCENCE — ses derniers souvenirs enregistrés ;
///  4. la FRÉQUENCE globale — à défaut d'autre chose, les habitués du carnet.
///
/// Chaque signal est une PROPORTION (part des souvenirs du sous-ensemble où la
/// personne figure), jamais un décompte : sinon la personne la plus taguée du
/// carnet remonterait partout.
List<PersonSuggestion> suggestPeople({
  required List<MemoryModel> memories,
  required List<TagModel> people,
  required Set<String> alreadySelected,
  required DateTime date,
  String location = '',
  int limit = 3,
}) {
  if (people.isEmpty || memories.isEmpty) return const [];

  final selectedLower = {
    for (final l in alreadySelected) l.trim().toLowerCase()
  };
  final candidates = [
    for (final t in people)
      if (t.label.trim().isNotEmpty &&
          !selectedLower.contains(t.label.trim().toLowerCase()))
        t
  ];
  if (candidates.isEmpty) return const [];

  // Les libellés de personnes connus servent à repérer les personnes d'un
  // souvenir : `tagKinds` est absent des souvenirs d'avant le 15.09.26, le
  // recoupement par libellé marche partout.
  final peopleLabels = {
    for (final t in people) t.label.trim().toLowerCase(): t.label.trim()
  };

  Set<String> peopleOf(MemoryModel m) {
    final out = <String>{};
    for (final raw in m.tagLabels) {
      final key = raw.trim().toLowerCase();
      if (peopleLabels.containsKey(key)) out.add(key);
    }
    return out;
  }

  final loc = location.trim().toLowerCase();
  // Un souvenir est « au même lieu » par son champ lieu OU par un tag de même
  // libellé (le lieu est aussi posé en tag à la création).
  bool sameLocation(MemoryModel m) {
    if (loc.isEmpty) return false;
    if ((m.location ?? '').trim().toLowerCase() == loc) return true;
    return m.tagLabels.any((l) => l.trim().toLowerCase() == loc);
  }

  // ±45 jours : large assez pour un voyage ou des vacances scolaires, étroit
  // assez pour ne pas englober toute l'année.
  bool nearDate(MemoryModel m) =>
      m.date.difference(date).inDays.abs() <= 45;

  final byLocation = memories.where(sameLocation).toList();
  final byDate = memories.where(nearDate).toList();
  final recent = [...memories]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final last20 = recent.take(20).toList();

  Map<String, double> rates(List<MemoryModel> subset) {
    if (subset.isEmpty) return const {};
    final counts = <String, int>{};
    for (final m in subset) {
      for (final p in peopleOf(m)) {
        counts[p] = (counts[p] ?? 0) + 1;
      }
    }
    return {
      for (final e in counts.entries) e.key: e.value / subset.length
    };
  }

  final rateLocation = rates(byLocation);
  final rateDate = rates(byDate);
  final rateRecent = rates(last20);
  final rateGlobal = rates(memories);

  final out = <PersonSuggestion>[];
  for (final tag in candidates) {
    final key = tag.label.trim().toLowerCase();
    final rl = rateLocation[key] ?? 0;
    final rd = rateDate[key] ?? 0;
    final rr = rateRecent[key] ?? 0;
    final rg = rateGlobal[key] ?? 0;

    // Jamais taguée nulle part : on ne la propose pas (un carnet neuf ne
    // propose donc rien, et c'est la bonne réponse).
    if (rg == 0) continue;

    var score = 3 * rl + 2 * rd + 1.5 * rr + rg;

    // Un tag enfant déjà présent dans le carnet et né avant ce souvenir est
    // presque toujours concerné — mais ça reste un coup de pouce, pas une
    // certitude : un souvenir peut très bien ne concerner que l'autre enfant.
    final birth = tag.birthdate;
    if (tag.isChild && birth != null && !date.isBefore(birth)) {
      score += 1.5;
    }

    String reason;
    if (rl >= 0.5 && loc.isNotEmpty) {
      reason = 'souvent à ${location.trim()}';
    } else if (rd >= 0.5) {
      reason = 'à cette période';
    } else if (rr >= 0.4) {
      reason = 'tes derniers souvenirs';
    } else if (tag.isChild) {
      reason = 'enfant du carnet';
    } else {
      reason = 'souvent dans tes souvenirs';
    }

    out.add(PersonSuggestion(tag: tag, reason: reason, score: score));
  }

  out.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0
        ? byScore
        : a.tag.label.toLowerCase().compareTo(b.tag.label.toLowerCase());
  });
  return out.take(limit).toList();
}
