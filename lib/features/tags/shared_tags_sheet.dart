import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/tag_service.dart';
import 'share_tag_sheet.dart';

/// Vue d'ensemble : quels tags (à moi) sont partagés, et avec qui — point
/// d'entrée central au partage depuis le dashboard. Avant, il fallait
/// filtrer par tag pour tomber par hasard sur l'icône de partage ; ce n'était
/// pas mis en avant du tout.
class SharedTagsSheet extends StatefulWidget {
  /// Déjà filtrés par l'appelant : tags dont je suis propriétaire ET
  /// effectivement partagés (sharedWith non vide) — voir home_screen.dart.
  final List<TagModel> tags;
  const SharedTagsSheet({super.key, required this.tags});

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
            const SizedBox(height: 16),
            if (widget.tags.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'Aucun tag partagé pour l\'instant — partage-en un depuis '
                  'le filtre par tag.',
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
