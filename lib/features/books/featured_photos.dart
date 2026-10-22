import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/widgets/media_fullscreen_viewer.dart';

// ── Photos « en grand » (pleine page dans le livre) ─────────────────────────
// Utilisé par la feuille de mise en page d'UN souvenir (MemoryLayoutSheet) ;
// le parcours livre a son propre écran de choix (book_photos_step.dart).
// Principe UX : toucher une photo l'ouvre en plein écran (on juge le cadrage,
// la netteté) ; l'étoile — sur la vignette ou en bas de la galerie — la met
// en grand. Avant, toucher = basculer, sans aucun moyen de voir la photo.

/// Photos d'un souvenir : identifiant STABLE (clé R2 ou URL legacy, celui
/// stocké dans bookFeaturedMedia) → URL affichable. Miroir de
/// PhotoService.resolvePhotoUrls, ordonné comme `rawMediaIdsOf` (= ordre des
/// pages du livre).
Future<Map<String, String>> loadFeaturablePhotos(MemoryModel m) async {
  final map = <String, String>{};
  if (m.mediaKeys.isNotEmpty) {
    map.addAll(await PhotoService.signedUrlsForMemory(m.id));
  }
  for (final u in m.mediaUrls) {
    map[u] = u;
  }
  if (map.isEmpty && m.photoUrl != null && m.photoUrl!.isNotEmpty) {
    map[m.photoUrl!] = m.photoUrl!;
  }
  final ordered = <String, String>{};
  for (final id in rawMediaIdsOf(m)) {
    final url = map[id];
    if (url != null) ordered[id] = url;
  }
  for (final e in map.entries) {
    ordered.putIfAbsent(e.key, () => e.value);
  }
  return ordered;
}

/// Bouton en bas de la galerie plein écran : « Mettre en grand » / « En grand ».
Widget featuredToggleButton({
  required bool featured,
  required VoidCallback onTap,
}) {
  return ElevatedButton.icon(
    onPressed: onTap,
    icon: Icon(featured ? Icons.star : Icons.star_border, size: 20),
    label: Text(featured
        ? 'En grand dans le livre'
        : 'Mettre en grand dans le livre'),
    style: ElevatedButton.styleFrom(
      backgroundColor: featured ? AppColors.sage : Colors.white,
      foregroundColor: featured ? Colors.white : AppColors.textDark,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
  );
}

/// Ouvre les photos en plein écran (zoom, balayage) avec le bouton de mise en
/// grand. [ids]/[urls] alignés ; [isFeatured]/[onToggle] pilotés par l'appelant.
Future<void> openFeaturedViewer(
  BuildContext context, {
  required List<String> ids,
  required List<String> urls,
  required int initialIndex,
  required bool Function(String id) isFeatured,
  required void Function(String id) onToggle,
}) {
  return MediaFullscreenViewer.open(
    context,
    items: [for (final u in urls) FullscreenMedia.photoUrl(u)],
    initialIndex: initialIndex,
    bottomAction: (i, refresh) => featuredToggleButton(
      featured: isFeatured(ids[i]),
      onTap: () {
        onToggle(ids[i]);
        refresh();
      },
    ),
  );
}

/// Vignette : toucher = voir en grand, étoile dans le coin = mettre en grand.
class FeaturedPhotoTile extends StatelessWidget {
  final String url;
  final bool featured;
  final VoidCallback onOpen;
  final VoidCallback onToggle;
  const FeaturedPhotoTile({
    super.key,
    required this.url,
    required this.featured,
    required this.onOpen,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: onOpen,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: AppColors.sageTint),
              errorWidget: (_, __, ___) => Container(
                color: AppColors.sageTint,
                child: const Icon(Icons.broken_image_outlined,
                    color: AppColors.softGray),
              ),
            ),
          ),
        ),
        if (featured)
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.sage, width: 3),
              ),
            ),
          ),
        Positioned(
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: featured
                      ? AppColors.sage
                      : Colors.black.withOpacity(0.45),
                  shape: BoxShape.circle,
                ),
                child: Icon(featured ? Icons.star : Icons.star_border,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
