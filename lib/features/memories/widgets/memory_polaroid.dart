import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/models/memory_model.dart';
import '../../../core/constants/milestone_types.dart';
import '../../../core/services/photo_service.dart';

/// Carte "polaroid" d'un souvenir (grille terracotta).
/// Partagée entre l'écran « Mes souvenirs » et le dashboard (3 derniers).
class MemoryPolaroid extends StatelessWidget {
  final MemoryModel memory;
  final MilestoneCategory? cat;
  final double tilt;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const MemoryPolaroid({
    super.key,
    required this.memory,
    required this.cat,
    required this.tilt,
    required this.onTap,
    this.onLongPress,
  });

  Widget _miniIcon(String e) => Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.45), shape: BoxShape.circle),
        child: Text(e, style: const TextStyle(fontSize: 10)),
      );

  @override
  Widget build(BuildContext context) {
    final photoCount = memory.mediaKeys.isNotEmpty
        ? memory.mediaKeys.length
        : (memory.mediaUrls.isNotEmpty
            ? memory.mediaUrls.length
            : (memory.photoUrl != null && memory.photoUrl!.isNotEmpty ? 1 : 0));
    final hasPhoto = photoCount > 0;
    final title = (memory.title?.trim().isNotEmpty ?? false)
        ? memory.title!.trim()
        : (memory.rawContent.trim().isNotEmpty
            ? memory.rawContent.trim()
            : 'Souvenir');
    String date;
    try {
      date = DateFormat('d MMM', 'fr').format(memory.date).toUpperCase();
    } catch (_) {
      date = '';
    }
    final loc = memory.location?.trim() ?? '';
    final sub = loc.isNotEmpty ? '$date · ${loc.toUpperCase()}' : date;
    final hasVideo = memory.videoKeys.isNotEmpty;
    final hasAudio = memory.audioUrl != null && memory.audioUrl!.isNotEmpty;

    return Transform.rotate(
      angle: tilt,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.10),
                  blurRadius: 16,
                  offset: const Offset(0, 8)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasPhoto)
                        FutureBuilder<List<String>>(
                          future: PhotoService.resolvePhotoUrls(memory),
                          builder: (_, snap) {
                            final url = (snap.data?.isNotEmpty ?? false)
                                ? snap.data!.first
                                : null;
                            if (url == null) {
                              return Container(color: AppColors.sageTint);
                            }
                            return CachedNetworkImage(
                              imageUrl: url,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: AppColors.sageTint),
                              errorWidget: (_, __, ___) =>
                                  Container(color: AppColors.sageTint),
                            );
                          },
                        )
                      else
                        Container(
                          color: AppColors.sageTint,
                          alignment: Alignment.center,
                          child: Text(cat?.emoji ?? '📝',
                              style: const TextStyle(fontSize: 34)),
                        ),
                      if (cat != null)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Transform.rotate(
                            angle: -0.04,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.95),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(cat!.emoji,
                                      style: const TextStyle(fontSize: 11)),
                                  const SizedBox(width: 4),
                                  Text(cat!.label,
                                      style: const TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textDark)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (hasVideo || hasAudio)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Row(
                            children: [
                              if (hasVideo) _miniIcon('🎬'),
                              if (hasAudio) ...[
                                const SizedBox(width: 4),
                                _miniIcon('🎙'),
                              ],
                            ],
                          ),
                        ),
                      if (hasPhoto)
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text('$photoCount 📷',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: 'Fraunces',
                      fontStyle: FontStyle.italic,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textDark)),
              const SizedBox(height: 3),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10,
                      letterSpacing: 0.5,
                      color: AppColors.textMedium)),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}
