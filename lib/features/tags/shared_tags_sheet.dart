import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/tag_service.dart';
import 'share_tag_sheet.dart';
import 'tag_picker_sheet.dart';

/// Vue d'ensemble : quels tags (à moi) sont partagés, et avec qui — point
/// d'entrée central au partage depuis le dashboard. Avant, il fallait
/// filtrer par tag pour tomber par hasard sur l'icône de partage ; ce n'était
/// pas mis en avant du tout.
class SharedTagsSheet extends StatefulWidget {
  /// Déjà filtrés par l'appelant : tags dont je suis propriétaire ET
  /// effectivement partagés (sharedWith non vide) — voir home_screen.dart.
  final List<TagModel> tags;

  /// TOUS mes tags (partagés ou non) — source du sélecteur « Partager un
  /// nouveau tag ». Avant, la seule façon de démarrer un NOUVEAU partage
  /// était de deviner qu'il fallait aller filtrer par tag dans « Mes
  /// souvenirs » : cette feuille ne montrait que les tags déjà partagés,
  /// sans aucun moyen d'en partager un de plus depuis ici.
  final List<TagModel> ownedTags;
  const SharedTagsSheet({super.key, required this.tags, required this.ownedTags});

  @override
  State<SharedTagsSheet> createState() => _SharedTagsSheetState();
}

class _SharedTagsSheetState extends State<SharedTagsSheet> {
  Map<String, ({String email, String displayName})> _collabs = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.tags.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final resolved = await TagService.resolveCollaborators(
        [for (final t in widget.tags) t.id]);
    if (mounted) {
      setState(() {
        _collabs = resolved;
        _loading = false;
      });
    }
  }

  String _label(String uid) {
    final info = _collabs[uid];
    if (info == null) return uid;
    return info.displayName.isNotEmpty ? info.displayName : info.email;
  }

  Future<void> _shareNewTag() async {
    final selected = await showTagPickerSheet(
      context,
      tags: widget.ownedTags,
      initialLabels: const {},
      title: 'Quel tag partager ?',
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    final toShare = widget.ownedTags
        .where((t) => selected.contains(t.label.trim()))
        .toList();
    if (toShare.isEmpty || !mounted) return;
    Navigator.pop(context);
    showShareTagSheet(context, toShare);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: AppColors.softGray,
                    borderRadius: BorderRadius.circular(99)),
              ),
            ),
            const Text('Tags partagés',
                style: TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
            const SizedBox(height: 4),
            const Text(
              'Qui voit quoi — tape un tag pour renvoyer le lien.',
              style: TextStyle(fontSize: 12.5, color: AppColors.textMedium),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: widget.ownedTags.isEmpty ? null : _shareNewTag,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Partager un nouveau tag'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.sageDark,
                  side: const BorderSide(color: AppColors.sageDark),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (widget.tags.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Aucun tag partagé pour l\'instant.',
                  style: TextStyle(color: AppColors.textMedium, fontSize: 13.5),
                ),
              )
            else if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.tags.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final tag = widget.tags[i];
                    final names = tag.sharedWith.map(_label).join(', ');
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        showShareTagSheet(context, [tag]);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.border, width: 0.5),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.sell_outlined,
                                color: AppColors.sage, size: 18),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(tag.label,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textDark)),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Avec $names',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 12, color: AppColors.textMedium),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.ios_share,
                                color: AppColors.softGray, size: 18),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
