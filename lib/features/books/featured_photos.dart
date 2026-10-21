import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/widgets/media_fullscreen_viewer.dart';

// ── Photos « en grand » (pleine page dans le livre) ─────────────────────────
// Partagé entre la feuille de mise en page d'UN souvenir (MemoryLayoutSheet)
// et l'étape « Photos en grand » du parcours livre (FeaturedPhotosPanel).
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

/// Étape « Photos en grand » du parcours livre : toutes les photos des
/// souvenirs choisis, regroupées par souvenir, pour décider d'un coup celles
/// qui prendront une page entière.
///
/// Chaque étoile est enregistrée TOUT DE SUITE sur le souvenir
/// (`bookFeaturedMedia`, réglage du souvenir et non propre à ce livre) puis
/// remontée par [onMemoryUpdated] — plus de bouton « Enregistrer » à ne pas
/// oublier. Avant le 21.10.26 c'était un écran séparé (FeaturedPhotosScreen).
class FeaturedPhotosPanel extends StatefulWidget {
  final List<MemoryModel> memories;
  final ValueChanged<MemoryModel> onMemoryUpdated;

  /// Contenu posé au-dessus de la grille (bandeau de l'étape).
  final Widget? header;

  const FeaturedPhotosPanel({
    super.key,
    required this.memories,
    required this.onMemoryUpdated,
    this.header,
  });

  @override
  State<FeaturedPhotosPanel> createState() => _FeaturedPhotosPanelState();
}

class _FeaturedPhotosPanelState extends State<FeaturedPhotosPanel> {
  late List<MemoryModel> _memories;
  final Map<String, Map<String, String>> _photos = {}; // memoryId -> id->url
  final Map<String, Set<String>> _featured = {}; // memoryId -> ids
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _memories = widget.memories
        .where((m) => m.type != 'taille_poids')
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    for (final m in _memories) {
      _featured[m.id] = {...m.bookFeaturedMedia};
    }
    _load();
  }

  Future<void> _load() async {
    // Concurrence bornée : un livre peut compter des dizaines de souvenirs.
    var next = 0;
    Future<void> worker() async {
      while (next < _memories.length) {
        final m = _memories[next++];
        try {
          _photos[m.id] = await loadFeaturablePhotos(m);
        } catch (_) {
          _photos[m.id] = const {};
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    if (mounted) setState(() => _loading = false);
  }

  int get _featuredCount =>
      _featured.values.fold(0, (sum, s) => sum + s.length);

  bool _isFeatured(String memoryId, String id) =>
      _featured[memoryId]?.contains(id) ?? false;

  Future<void> _toggle(String memoryId, String id) async {
    final set = _featured.putIfAbsent(memoryId, () => {});
    final wasFeatured = set.contains(id);
    setState(() => wasFeatured ? set.remove(id) : set.add(id));
    final i = _memories.indexWhere((m) => m.id == memoryId);
    if (i == -1) return;
    final ids = set.toList();
    try {
      await FirebaseFirestore.instance
          .collection('memories')
          .doc(memoryId)
          .update({'bookFeaturedMedia': ids});
      final updated = _memories[i].copyWith(bookFeaturedMedia: ids);
      _memories[i] = updated;
      widget.onMemoryUpdated(updated);
    } catch (_) {
      if (!mounted) return;
      setState(() => wasFeatured ? set.add(id) : set.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Impossible d\'enregistrer — réessaie.'),
      ));
    }
  }

  /// Galerie sur TOUTES les photos du livre (on balaie d'un souvenir à
  /// l'autre), ouverte sur la photo touchée.
  void _openViewer(String memoryId, String id) {
    final ids = <String>[];
    final urls = <String>[];
    final owners = <String>[];
    var initial = 0;
    for (final m in _memories) {
      for (final e in (_photos[m.id] ?? const {}).entries) {
        if (m.id == memoryId && e.key == id) initial = ids.length;
        ids.add(e.key);
        urls.add(e.value);
        owners.add(m.id);
      }
    }
    openFeaturedViewer(
      context,
      ids: ids,
      urls: urls,
      initialIndex: initial,
      isFeatured: (pid) => _isFeatured(owners[ids.indexOf(pid)], pid),
      onToggle: (pid) => _toggle(owners[ids.indexOf(pid)], pid),
    );
  }

  @override
  Widget build(BuildContext context) {
    final withPhotos =
        _memories.where((m) => (_photos[m.id] ?? const {}).isNotEmpty).toList();
    final dateFmt = DateFormat('d MMM yyyy', 'fr');
    return CustomScrollView(
      slivers: [
        if (widget.header != null) SliverToBoxAdapter(child: widget.header!),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          sliver: SliverToBoxAdapter(
            child: Text(
              _featuredCount == 0
                  ? 'Touche une photo pour la voir en grand, et ☆ pour '
                      'qu\'elle occupe une page entière. Facultatif : sans '
                      'choix, la mise en page est automatique.'
                  : '$_featuredCount photo${_featuredCount > 1 ? 's' : ''} '
                      'en pleine page · enregistré automatiquement',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textMedium, height: 1.4),
            ),
          ),
        ),
        if (_loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (withPhotos.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Text('Aucune photo dans les souvenirs choisis.',
                    style: TextStyle(color: AppColors.textMedium)),
              ),
            ),
          )
        else
          for (final m in withPhotos) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                      text: (m.title?.isNotEmpty ?? false)
                          ? m.title!
                          : 'Souvenir',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDark,
                          fontSize: 14)),
                  TextSpan(
                      text: '  ·  ${dateFmt.format(m.date)}',
                      style: const TextStyle(
                          color: AppColors.textMedium, fontSize: 12)),
                ])),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid.count(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (final e in _photos[m.id]!.entries)
                    FeaturedPhotoTile(
                      url: e.value,
                      featured: _isFeatured(m.id, e.key),
                      onOpen: () => _openViewer(m.id, e.key),
                      onToggle: () => _toggle(m.id, e.key),
                    ),
                ],
              ),
            ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}
