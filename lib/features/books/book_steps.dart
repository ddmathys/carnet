import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Parcours de création d'un livre, étape par étape (21.10.26) — même
/// principe que l'enregistrement d'un souvenir. L'étape 1 (souvenirs) vit
/// dans MemorySelectScreen, les suivantes dans BookGenerateScreen.
const bookStepLabels = [
  'Souvenirs',
  'Photos en grand',
  'Titre & dédicace',
  'Couverture',
  'Aperçu',
  'Format',
  'Commande',
];

/// Indices globaux des étapes (voir [bookStepLabels]).
abstract final class BookStep {
  static const memories = 0;
  static const featured = 1;
  static const title = 2;
  static const cover = 3;
  static const preview = 4;
  static const format = 5;
  static const order = 6;
}

/// En-tête du parcours : « ÉTAPE X / 7 · NOM », puces de progression
/// touchables pour revenir à une étape, et une ligne d'état facultative
/// (brouillon enregistré, aperçu en préparation…).
class BookStepHeader extends StatelessWidget {
  final int index;

  /// Dernière étape accessible d'un toucher sur sa puce.
  final int maxReachable;
  final ValueChanged<int>? onTapStep;
  final String? status;
  final bool statusBusy;

  const BookStepHeader({
    super.key,
    required this.index,
    this.maxReachable = 0,
    this.onTapStep,
    this.status,
    this.statusBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    final total = bookStepLabels.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'ÉTAPE ${index + 1} / $total · '
                  '${bookStepLabels[index].toUpperCase()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 10.5,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textMedium,
                  ),
                ),
              ),
              for (var i = 0; i < total; i++)
                Semantics(
                  button: onTapStep != null && i <= maxReachable,
                  label: bookStepLabels[i],
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTapStep != null && i <= maxReachable && i != index
                        ? () => onTapStep!(i)
                        : null,
                    child: Padding(
                      // Zone de toucher plus large que la puce elle-même.
                      padding: const EdgeInsets.symmetric(
                          horizontal: 3, vertical: 10),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: i == index ? 16 : 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: i <= index
                              ? AppColors.sageDark
                              : i <= maxReachable
                                  ? AppColors.sage
                                  : AppColors.softGray,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (status != null)
            Row(
              children: [
                if (statusBusy)
                  const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: AppColors.sage),
                  )
                else
                  const Icon(Icons.cloud_done_outlined,
                      size: 13, color: AppColors.sage),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    status!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textMedium),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
