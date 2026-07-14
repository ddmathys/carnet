import 'package:flutter/material.dart';
import '../../../core/models/memory_model.dart';
import '../../../core/services/photo_service.dart';
import '../../../core/theme/app_theme.dart';

/// Suppression définitive d'un souvenir, depuis n'importe quel écran.
///
/// Popup de confirmation qui NOMME ce qu'on s'apprête à perdre (photos, vidéos,
/// mémo vocal) — puis suppression complète : le document Firestore *et* tous les
/// médias associés, sur R2 comme sur l'ancien Firebase Storage. Rien ne survit,
/// rien ne reste à payer dans un coin du stockage.
///
/// Renvoie true si le souvenir a bien été supprimé.
Future<bool> confirmAndDeleteMemory(
    BuildContext context, MemoryModel memory) async {
  final photos = memory.mediaKeys.length +
      memory.mediaUrls.length +
      ((memory.mediaKeys.isEmpty &&
              memory.mediaUrls.isEmpty &&
              (memory.photoUrl?.isNotEmpty ?? false))
          ? 1
          : 0);
  final videos = memory.videoKeys.length;
  final hasAudio = (memory.audioKey?.isNotEmpty ?? false) ||
      (memory.audioUrl?.isNotEmpty ?? false);

  final parts = <String>[
    if (photos > 0) '$photos photo${photos > 1 ? 's' : ''}',
    if (videos > 0) '$videos vidéo${videos > 1 ? 's' : ''}',
    if (hasAudio) 'le mémo vocal',
  ];
  final title = (memory.title?.trim().isNotEmpty ?? false)
      ? memory.title!.trim()
      : 'Ce souvenir';

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text(
        'Supprimer ce souvenir ?',
        style: TextStyle(
          fontFamily: 'Fraunces',
          fontWeight: FontWeight.w600,
          color: AppColors.textDark,
        ),
      ),
      content: Text(
        parts.isEmpty
            ? '« $title » sera supprimé définitivement.'
            : '« $title » sera supprimé définitivement, avec ${parts.join(', ')}.\n\n'
                'Cette action est irréversible.',
        style: const TextStyle(color: AppColors.textMedium, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annuler',
              style: TextStyle(color: AppColors.textMedium)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.error,
            foregroundColor: Colors.white,
          ),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  await PhotoService.deleteMemory(
    memory.id,
    memory.photoUrl,
    memory.mediaUrls,
    audioUrl: memory.audioUrl,
    audioKey: memory.audioKey,
    videoKeys: memory.videoKeys,
    mediaKeys: memory.mediaKeys,
  );
  return true;
}
