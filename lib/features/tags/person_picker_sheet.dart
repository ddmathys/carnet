import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/tag_service.dart';
import 'person_avatar.dart';

/// Sélecteur de personnes — la version « juste les personnes » du sélecteur
/// de tags : une liste des personnes déjà connues (tags `kind == 'personne'`),
/// à cocher, plus un champ pour en ajouter une nouvelle. Contrairement au tag
/// libre, une personne ajoutée ici est reconnue comme telle tout de suite
/// (pas besoin d'un appui long après coup) — c'est ce qui la fait ressortir
/// dans le filtre « Personne » et proposer comme sujet de rétrospective.
///
/// Renvoie les libellés retenus, ou null si annulé.
Future<Set<String>?> showPersonPickerSheet(
  BuildContext context, {
  required List<TagModel> tags,
  required Set<String> initialLabels,
}) {
  return showModalBottomSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PersonPickerSheet(
      tags: tags,
      initialLabels: initialLabels,
    ),
  );
}

class _PersonPickerSheet extends StatefulWidget {
  final List<TagModel> tags;
  final Set<String> initialLabels;

  const _PersonPickerSheet({required this.tags, required this.initialLabels});

  @override
  State<_PersonPickerSheet> createState() => _PersonPickerSheetState();
}

class _PersonPickerSheetState extends State<_PersonPickerSheet> {
  late final Set<String> _selected = {...widget.initialLabels};
  // Nouvelles personnes tapées à la volée : pas encore en base, mais doivent
  // apparaître (et rester cochées) dans la feuille.
  final List<String> _created = [];
  final _newCtrl = TextEditingController();
  // Tags résolus/créés pendant cette session (photo ajoutée, ou nouvelle
  // personne créée en base pour pouvoir lui poser une photo tout de suite) :
  // `widget.tags` est figé, on garde ici ce qui change en local.
  final Map<String, TagModel> _tagOverrides = {};

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  TagModel? _tagFor(String label) {
    final key = label.trim().toLowerCase();
    final override = _tagOverrides[key];
    if (override != null) return override;
    for (final t in widget.tags) {
      if (t.kind == 'personne' && t.label.trim().toLowerCase() == key) {
        return t;
      }
    }
    return null;
  }

  /// Appui long sur une personne → lui donner/changer sa photo de tête. Une
  /// personne pas encore enregistrée (tapée à l'instant) est créée en base au
  /// passage — sans ça, impossible de lui attacher une photo.
  Future<void> _editPhoto(String label) async {
    final tag = _tagFor(label) ?? await TagService.ensureTag(label, kind: 'personne');
    if (tag == null || !mounted) return;
    final updated = await editPersonPhoto(context, tag);
    if (updated == null || !mounted) return;
    setState(() => _tagOverrides[label.trim().toLowerCase()] = updated);
  }

  List<String> get _people {
    final seen = <String>{};
    final out = <String>[];
    for (final t in widget.tags) {
      if (t.kind != 'personne') continue;
      final label = t.label.trim();
      if (label.isEmpty || !seen.add(label.toLowerCase())) continue;
      out.add(label);
    }
    for (final label in _created) {
      if (seen.add(label.toLowerCase())) out.add(label);
    }
    out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }

  void _addNew() {
    final label = _newCtrl.text.trim();
    if (label.isEmpty) return;
    setState(() {
      if (!_created.contains(label) &&
          !widget.tags.any(
              (t) => t.kind == 'personne' && t.label == label)) {
        _created.add(label);
      }
      _selected.add(label);
      _newCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;

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
                const Expanded(
                  child: Text(
                    'Personnes',
                    style: TextStyle(
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
                  if (people.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Aucune personne pour l\'instant — ajoute la '
                        'première ci-dessous.',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textMedium),
                      ),
                    )
                  else ...[
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Appui long sur une personne pour lui donner une photo.',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textMedium),
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final label in people)
                          GestureDetector(
                            onTap: () => setState(() {
                              if (!_selected.remove(label)) {
                                _selected.add(label);
                              }
                            }),
                            onLongPress: () => _editPhoto(label),
                            child: _PersonChip(
                              label: label,
                              selected: _selected.contains(label),
                              photoKey: _tagFor(label)?.photoKey,
                              colorHex: _tagFor(label)?.color ?? '#C4714B',
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _newCtrl,
                          textCapitalization: TextCapitalization.words,
                          onSubmitted: (_) => _addNew(),
                          decoration: const InputDecoration(
                            hintText: 'Nouvelle personne…',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _addNew,
                        icon: const Icon(Icons.add_circle,
                            color: AppColors.sageDark, size: 30),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
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

class _PersonChip extends StatelessWidget {
  final String label;
  final bool selected;
  final String? photoKey;
  final String colorHex;
  const _PersonChip({
    required this.label,
    required this.selected,
    this.photoKey,
    this.colorHex = '#C4714B',
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
          PersonAvatar(
              label: label, photoKey: photoKey, colorHex: colorHex, size: 20),
          const SizedBox(width: 6),
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
