import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/media_upload_queue.dart';

/// Bannière discrète reflétant la file d'upload en arrière-plan :
/// « Envoi en cours… » avec une barre de progression pendant que les
/// photos/vidéos/mémos partent, ou une bannière d'erreur avec « Réessayer »
/// si un envoi a échoué. Disparaît une fois tout terminé (le média apparaît
/// tout seul via le flux Firestore live).
///
/// Partagée entre le dashboard et la liste des souvenirs : le souvenir se
/// sauvegarde et se ferme tout de suite, les médias partent en arrière-plan,
/// et cette bannière (visible sur les deux écrans) dit quand on peut
/// vraiment quitter l'application.
class UploadStatusBanner extends StatelessWidget {
  const UploadStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MediaUploadQueue.instance,
      builder: (context, _) {
        final q = MediaUploadQueue.instance;
        if (q.pending > 0) {
          final n = q.pending;
          final vp = q.videoProgress; // null si aucune vidéo en cours
          final pp = q.photoProgress; // null si aucune photo en cours
          // La vidéo (plus lourde) est prioritaire ; sinon on suit les photos.
          final frac = vp ?? pp;
          final pct = frac != null ? (frac * 100).round() : null;
          final String title;
          if (q.videoTotal > 1) {
            title = 'Envoi de la vidéo ${q.videoIndex}/${q.videoTotal}…';
          } else if (vp != null) {
            title = 'Envoi de la vidéo…';
          } else if (pp != null) {
            title = q.photoTotal > 1
                ? 'Envoi des photos ${q.photoDone}/${q.photoTotal}…'
                : 'Envoi de la photo…';
          } else {
            title = n == 1
                ? 'Envoi du souvenir en cours…'
                : 'Envoi de $n souvenirs en cours…';
          }
          return _strip(
            color: AppColors.sage.withOpacity(0.12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        pct != null ? '$title $pct %' : title,
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textDark,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    // Déterminée pendant l'envoi d'une vidéo ou des photos,
                    // indéterminée sinon (mémo/écriture, non suivis en détail).
                    value: frac,
                    minHeight: 6,
                    backgroundColor: AppColors.sage.withOpacity(0.18),
                    valueColor:
                        const AlwaysStoppedAnimation(AppColors.sageDark),
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Tu peux quitter cette page — garde juste l\'application '
                  'ouverte le temps de l\'envoi.',
                  style: TextStyle(fontSize: 11, color: AppColors.textMedium),
                ),
              ],
            ),
          );
        }
        if (q.failed.isNotEmpty) {
          final n = q.failed.length;
          final reason = q.lastError;
          return _strip(
            color: AppColors.error.withOpacity(0.10),
            child: Row(
              children: [
                const Icon(Icons.cloud_off_outlined,
                    size: 16, color: AppColors.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    (n == 1
                            ? 'Échec de l\'envoi des médias'
                            : 'Échec de l\'envoi de $n souvenirs') +
                        (reason != null ? ' — $reason' : ''),
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.error),
                  ),
                ),
                TextButton(
                  onPressed: q.retryFailed,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Réessayer',
                      style: TextStyle(
                          color: AppColors.error,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5)),
                ),
              ],
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _strip({required Color color, required Widget child}) => Container(
        width: double.infinity,
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: child,
      );
}
