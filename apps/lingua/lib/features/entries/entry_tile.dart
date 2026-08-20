import 'package:flutter/material.dart';

import '../../core/models/vocab_entry.dart';

/// Une entrée dans la liste : le mot, sa traduction, la phrase où on l'a
/// croisé, et son thème.
class EntryTile extends StatelessWidget {
  const EntryTile({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onToggleLearned,
    required this.onDelete,
    this.onCategoryTap,
  });

  final VocabEntry entry;
  final VoidCallback onTap;
  final VoidCallback onToggleLearned;
  final VoidCallback onDelete;

  /// Filtrer sur le thème de l'entrée. `null` si elle n'en a pas.
  final VoidCallback? onCategoryTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (entry.isLearned) ...<Widget>[
                          Icon(Icons.check_circle,
                              size: 16, color: colors.primary),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            entry.term,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: entry.isLearned ? colors.outline : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (entry.translation.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(entry.translation, style: theme.textTheme.bodyMedium),
                    ],
                    if (entry.context.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        '« ${entry.context} »',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (entry.category.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 10),
                      _CategoryChip(
                        label: entry.category,
                        onTap: onCategoryTap,
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Actions',
                onSelected: (String value) {
                  if (value == 'learned') {
                    onToggleLearned();
                  } else if (value == 'delete') {
                    onDelete();
                  } else if (value == 'edit') {
                    onTap();
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'learned',
                    child: Text(entry.isLearned
                        ? 'Remettre à revoir'
                        : 'Marquer comme acquis'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'edit',
                    child: Text('Modifier'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Text('Supprimer'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: content,
    );
  }
}
