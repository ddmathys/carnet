import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';

/// Les trois familles de tags présentées à l'utilisateur.
/// Elles se déduisent du `kind` du tag : une année → Date, un lieu → Lieu, le
/// reste (tags libres, tag enfant) → Événement.
enum TagCategory { date, lieu, evenement }

extension TagCategoryX on TagCategory {
  String get label => switch (this) {
        TagCategory.date => 'Date',
        TagCategory.lieu => 'Lieu',
        TagCategory.evenement => 'Événement',
      };

  IconData get icon => switch (this) {
        TagCategory.date => Icons.event_outlined,
        TagCategory.lieu => Icons.place_outlined,
        TagCategory.evenement => Icons.local_offer_outlined,
      };
}

TagCategory categoryOf(TagModel tag) => switch (tag.kind) {
      'annee' => TagCategory.date,
      'lieu' => TagCategory.lieu,
      _ => TagCategory.evenement,
    };

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

  @override
  void dispose() {
    _newTagCtrl.dispose();
    super.dispose();
  }

  Map<TagCategory, List<String>> get _byCategory {
    final map = <TagCategory, List<String>>{
      for (final c in TagCategory.values) c: [],
    };
    for (final t in widget.tags) {
      map[categoryOf(t)]!.add(t.label);
    }
    // Les tags créés à l'instant sont des événements tant qu'ils n'ont pas de
    // kind — c'est le cas courant (« Vacances », « Amis »).
    for (final label in _created) {
      if (!map[TagCategory.evenement]!.contains(label)) {
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
        color: selected ? AppColors.sageDark : AppColors.white,
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
