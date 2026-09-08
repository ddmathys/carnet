import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/tag_service.dart';

/// Les familles de tags présentées à l'utilisateur.
/// Elles se déduisent du `kind` du tag : une année → Date, un lieu → Lieu, une
/// personne → Personne, le reste (tags libres) → Événement.
enum TagCategory { date, personne, lieu, evenement }

extension TagCategoryX on TagCategory {
  String get label => switch (this) {
        TagCategory.date => 'Date',
        TagCategory.personne => 'Personne',
        TagCategory.lieu => 'Lieu',
        TagCategory.evenement => 'Événement',
      };

  IconData get icon => switch (this) {
        TagCategory.date => Icons.event_outlined,
        TagCategory.personne => Icons.person_outline,
        TagCategory.lieu => Icons.place_outlined,
        TagCategory.evenement => Icons.local_offer_outlined,
      };

  /// Le `kind` Firestore correspondant (l'inverse de [categoryOfKind]).
  String get kind => switch (this) {
        TagCategory.date => 'annee',
        TagCategory.personne => 'personne',
        TagCategory.lieu => 'lieu',
        TagCategory.evenement => 'libre',
      };
}

TagCategory categoryOfKind(String kind) => switch (kind) {
      'annee' => TagCategory.date,
      // Un tag « enfant » (porte une date de naissance, débloque la courbe de
      // croissance) EST une personne — sans ça il retombait sous « Événement »
      // et n'apparaissait ni dans le filtre Personne, ni comme sujet de
      // rétrospective. Son `kind` reste 'enfant' (jamais réécrit ici) : c'est
      // uniquement le rangement visuel qui change.
      'personne' || 'enfant' => TagCategory.personne,
      'lieu' => TagCategory.lieu,
      _ => TagCategory.evenement,
    };

TagCategory categoryOf(TagModel tag) => categoryOfKind(tag.kind);

/// Un souvenir correspond-il à la sélection de tags ?
///
/// Règle de filtre classique : **OU à l'intérieur d'une catégorie, ET entre les
/// catégories**. « 2025, 2026 + Genève » = les souvenirs de 2025 *ou* 2026 qui
/// sont *aussi* à Genève — c'est ce qu'on attend en cochant plusieurs cases.
bool memoryMatchesTags(MemoryModel memory, List<TagModel> selectedTags) {
  if (selectedTags.isEmpty) return true;
  final byCategory = <TagCategory, List<TagModel>>{};
  for (final t in selectedTags) {
    byCategory.putIfAbsent(categoryOf(t), () => []).add(t);
  }
  for (final tags in byCategory.values) {
    final hitsCategory = tags.any((t) => memory.tagIds.contains(t.id));
    if (!hitsCategory) return false;
  }
  return true;
}

/// Ouvre le sélecteur de tags. Renvoie les libellés retenus, ou null si annulé.
///
/// [allowCreate] ajoute un champ « nouveau tag » (création de souvenir) ; sans
/// lui, la feuille sert de filtre (dashboard, liste).
Future<Set<String>?> showTagPickerSheet(
  BuildContext context, {
  required List<TagModel> tags,
  required Set<String> initialLabels,
  bool allowCreate = false,
  String title = 'Filtrer par tag',
}) {
  return showModalBottomSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _TagPickerSheet(
      tags: tags,
      initialLabels: initialLabels,
      allowCreate: allowCreate,
      title: title,
    ),
  );
}

class _TagPickerSheet extends StatefulWidget {
  final List<TagModel> tags;
  final Set<String> initialLabels;
  final bool allowCreate;
  final String title;

  const _TagPickerSheet({
    required this.tags,
    required this.initialLabels,
    required this.allowCreate,
    required this.title,
  });

  @override
  State<_TagPickerSheet> createState() => _TagPickerSheetState();
}

class _TagPickerSheetState extends State<_TagPickerSheet> {
  late final Set<String> _selected = {...widget.initialLabels};
  // Tags créés à la volée : ils n'existent pas encore en base, mais doivent
  // apparaître (et rester cochés) dans la feuille.
  final List<String> _created = [];
  final _newTagCtrl = TextEditingController();
  // Reclassements faits à l'instant (libellé minuscule → nouveau `kind`) : la
  // feuille reçoit une liste de tags figée, on garde donc les changements en
  // local pour que la puce change de section tout de suite. La base, elle, est
  // déjà mise à jour par TagService.setKindByLabel.
  final Map<String, String> _kindOverride = {};

  @override
  void dispose() {
    _newTagCtrl.dispose();
    super.dispose();
  }

  Map<TagCategory, List<String>> get _byCategory {
    final map = <TagCategory, List<String>>{
      for (final c in TagCategory.values) c: [],
    };
    // La feuille travaille en LIBELLÉS, pas en documents : deux tags de même nom
    // (un souvenir partagé, un doublon en base) ne doivent donner qu'une puce —
    // sinon « 2025 » s'affiche deux fois. Cocher ce libellé sélectionne bien
    // tous les tags qui le portent, côté écran appelant.
    final seen = <String>{};
    for (final t in widget.tags) {
      final label = t.label.trim();
      if (label.isEmpty || !seen.add(label.toLowerCase())) continue;
      final override = _kindOverride[label.toLowerCase()];
      final category =
          override != null ? categoryOfKind(override) : categoryOf(t);
      map[category]!.add(label);
    }
    // Les tags créés à l'instant sont des événements tant qu'ils n'ont pas de
    // kind — c'est le cas courant (« Vacances », « Amis »).
    for (final label in _created) {
      if (seen.add(label.toLowerCase())) {
        map[TagCategory.evenement]!.add(label);
      }
    }
    for (final list in map.values) {
      list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    // Les années, du plus récent au plus ancien — plus utile qu'un tri alpha.
    map[TagCategory.date]!.sort((a, b) => b.compareTo(a));
    return map;
  }

  void _addNewTag() {
    final label = _newTagCtrl.text.trim();
    if (label.isEmpty) return;
    setState(() {
      if (!_created.contains(label) &&
          !widget.tags.any((t) => t.label == label)) {
        _created.add(label);
      }
      _selected.add(label);
      _newTagCtrl.clear();
    });
  }

  /// Appui long sur une puce → petit menu pour changer sa nature (Personne,
  /// Lieu, Événement…). C'est ce qui permet de distinguer une personne comme on
  /// distingue déjà une date ou un lieu. Ne concerne que les tags que je possède
  /// (les règles Firestore interdisent de modifier un tag partagé par autrui).
  Future<void> _reclassify(String label) async {
    TagModel? tag;
    for (final t in widget.tags) {
      if (t.userId == TagService.currentUid &&
          t.label.trim().toLowerCase() == label.toLowerCase()) {
        tag = t;
        break;
      }
    }
    if (tag == null) return;
    // Un tag enfant est déjà une « Personne » (voir categoryOfKind) et porte
    // une date de naissance — le reclasser perdrait la courbe de croissance.
    if (tag.isChild) return;
    HapticFeedback.selectionClick();
    final choice = await showModalBottomSheet<TagCategory>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(
                '« $label » — c\'est…',
                style: const TextStyle(
                  fontFamily: 'Fraunces',
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
            ),
            for (final c in const [
              TagCategory.personne,
              TagCategory.lieu,
              TagCategory.evenement,
              TagCategory.date,
            ])
              ListTile(
                leading: Icon(c.icon, color: AppColors.sageDark),
                title: Text(c.label),
                onTap: () => Navigator.pop(context, c),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await TagService.setKindByLabel(label, choice.kind);
    if (!mounted) return;
    setState(() => _kindOverride[label.toLowerCase()] = choice.kind);
  }

  @override
  Widget build(BuildContext context) {
    final categories = _byCategory;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.softGray,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      fontFamily: 'Fraunces',
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark,
                    ),
                  ),
                ),
                if (_selected.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(_selected.clear),
                    child: const Text('Tout effacer',
                        style: TextStyle(
                            color: AppColors.textMedium, fontSize: 13)),
                  ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in TagCategory.values)
                    if (categories[c]!.isNotEmpty) ...[
                      Row(
                        children: [
                          Icon(c.icon, size: 15, color: AppColors.textMedium),
                          const SizedBox(width: 6),
                          Text(
                            c.label.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              color: AppColors.textMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final label in categories[c]!)
                            GestureDetector(
                              onTap: () => setState(() {
                                if (!_selected.remove(label)) {
                                  _selected.add(label);
                                }
                              }),
                              onLongPress: () => _reclassify(label),
                              child: _Chip(
                                label: label,
                                selected: _selected.contains(label),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 18),
                    ],
                  if (widget.allowCreate) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newTagCtrl,
                            textCapitalization: TextCapitalization.sentences,
                            onSubmitted: (_) => _addNewTag(),
                            decoration: const InputDecoration(
                              hintText: 'Nouveau tag…',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _addNewTag,
                          icon: const Icon(Icons.add_circle,
                              color: AppColors.sageDark, size: 30),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 6, 22, 12),
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, _selected),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                child: Text(_selected.isEmpty
                    ? 'Valider'
                    : 'Valider (${_selected.length})'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Puce de tag, cochée ou non — le même visuel partout (filtre et formulaire).
class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  const _Chip({required this.label, required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? AppColors.sageDark : AppColors.surface,
        borderRadius: BorderRadius.circular(50),
        border: Border.all(
          color: selected ? AppColors.sageDark : AppColors.border,
          width: selected ? 1.5 : 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            const Icon(Icons.check, size: 14, color: Colors.white),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : AppColors.textMedium,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
