import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/models/memory_model.dart';
import '../../../core/models/tag_model.dart';
import '../../milestones/widgets/growth_multi_chart.dart';

/// Préfixe des « souvenirs courbe de croissance » dans une sélection :
/// `growth:<tagId enfant>`. Ce ne sont pas des documents Firestore — la carte
/// est calculée à chaque affichage depuis les mesures taille/poids de
/// l'enfant, donc toujours à jour (ajout, correction ou suppression d'une
/// mesure). BookGenerateScreen décode ces ids et y joint les mesures.
const growthSelectionPrefix = 'growth:';

String growthSelectionId(String childTagId) =>
    '$growthSelectionPrefix$childTagId';

/// Mesures taille/poids visibles, groupées par enfant (tag `enfant` réel
/// présent dans `tagIds`), triées par date — seulement les enfants ayant au
/// moins 2 mesures (même seuil que la page courbe du livre).
List<({TagModel child, List<MemoryModel> measures})> growthEntriesFor(
    List<MemoryModel> memories, List<TagModel> tags) {
  final children = tags.where((t) => t.isChild && !t.isVirtual).toList();
  final byChild = <String, List<MemoryModel>>{};
  for (final m in memories) {
    if (m.type != 'taille_poids') continue;
    if (m.heightCm == null && m.weightKg == null) continue;
    for (final c in children) {
      if (m.tagIds.contains(c.id)) {
        byChild.putIfAbsent(c.id, () => []).add(m);
        break;
      }
    }
  }
  return [
    for (final c in children)
      if ((byChild[c.id]?.length ?? 0) >= 2)
        (
          child: c,
          measures: byChild[c.id]!..sort((a, b) => a.date.compareTo(b.date)),
        ),
  ];
}

/// Carte « 📈 Courbe de croissance — Nathan », au format des polaroïds de la
/// liste des souvenirs. En sélection, se coche comme un souvenir.
class GrowthChartCard extends StatelessWidget {
  final TagModel child;
  final List<MemoryModel> measures;
  final VoidCallback onTap;
  final bool? selected;

  const GrowthChartCard({
    super.key,
    required this.child,
    required this.measures,
    required this.onTap,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final hasHeight = measures.any((m) => m.heightCm != null);
    final last = measures.last;
    final lastParts = [
      if (last.heightCm != null) '${last.heightCm!.toStringAsFixed(0)} cm',
      if (last.weightKg != null) '${last.weightKg!.toStringAsFixed(1)} kg',
    ].join(' · ');
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected == true ? AppColors.sageDark : AppColors.border,
            width: selected == true ? 2.5 : 0.6,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
                      decoration: BoxDecoration(
                        color: AppColors.sageTint,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: IgnorePointer(
                        child: LayoutBuilder(
                          builder: (_, c) => GrowthMultiChart(
                            notebook: child.asNotebook(),
                            measures: measures,
                            showWeight: !hasHeight,
                            compact: true,
                            chartHeight: (c.maxHeight - 12).clamp(40.0, 400.0),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (selected != null)
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: selected!
                              ? AppColors.sageDark
                              : Colors.black.withOpacity(0.45),
                          shape: BoxShape.circle,
                          border: selected!
                              ? null
                              : Border.all(
                                  color: Colors.white.withOpacity(0.8),
                                  width: 1.5),
                        ),
                        child: selected!
                            ? const Icon(Icons.check,
                                color: Colors.white, size: 18)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text('📈 Courbe de croissance',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
            const SizedBox(height: 2),
            Text(child.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.sageDark)),
            const SizedBox(height: 2),
            Text(
              '${measures.length} mesures · ${DateFormat('d MMM yyyy', 'fr').format(last.date)}'
              '${lastParts.isEmpty ? '' : ' · $lastParts'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 11, color: AppColors.textMedium),
            ),
          ],
        ),
      ),
    );
  }
}
