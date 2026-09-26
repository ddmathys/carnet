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
// et l'écran « Toutes les photos du livre » (FeaturedPhotosScreen).
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

/// Toutes les photos des souvenirs du livre, regroupées par souvenir, pour
/// choisir d'un coup celles qui prendront une page entière — au lieu d'ouvrir
/// la mise en page de chaque souvenir un par un. Sauvegarde à « Enregistrer » ;
/// renvoie (Navigator.pop) la liste des souvenirs modifiés.
class FeaturedPhotosScreen extends StatefulWidget {
  final List<MemoryModel> memories;
  const FeaturedPhotosScreen({super.key, required this.memories});

  static Future<List<MemoryModel>?> open(
      BuildContext context, List<MemoryModel> memories) {
    return Navigator.of(context).push<List<MemoryModel>>(
      MaterialPageRoute(
          builder: (_) => FeaturedPhotosScreen(memories: memories)),
    );
  }

  @override
  State<FeaturedPhotosScreen> createState() => _FeaturedPhotosScreenState();
}

class _FeaturedPhotosScreenState extends State<FeaturedPhotosScreen> {
  late final List<MemoryModel> _memories = widget.memories
      .where((m) => m.type != 'taille_poids')
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final Map<String, Map<String, String>> _photos = {}; // memoryId -> id->url
  final Map<String, Set<String>> _featured = {}; // memoryId -> ids
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
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

  void _toggle(String memoryId, String id) {
    setState(() {
      final set = _featured.putIfAbsent(memoryId, () => {});
      set.contains(id) ? set.remove(id) : set.add(id);
    });
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

  bool _changed(MemoryModel m) {
    final now = _featured[m.id] ?? const {};
    final before = m.bookFeaturedMedia.toSet();
    return now.length != before.length || !now.containsAll(before);
  }

  Future<void> _save() async {
    final changed = _memories.where(_changed).toList();
    if (changed.isEmpty) {
      Navigator.pop(context, const <MemoryModel>[]);
      return;
    }
    setState(() => _saving = true);
    try {
      final batch = FirebaseFirestore.instance.batch();
      final updated = <MemoryModel>[];
      for (final m in changed) {
        final ids = _featured[m.id]!.toList();
        batch.update(
            FirebaseFirestore.instance.collection('memories').doc(m.id),
            {'bookFeaturedMedia': ids});
        updated.add(m.copyWith(bookFeaturedMedia: ids));
      }
      await batch.commit();
      if (mounted) Navigator.pop(context, updated);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Échec de la sauvegarde — réessaie.'),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final withPhotos =
        _memories.where((m) => (_photos[m.id] ?? const {}).isNotEmpty).toList();
    final dateFmt = DateFormat('d MMM yyyy', 'fr');
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('Photos en grand'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : withPhotos.isEmpty
              ? const Center(
                  child: Text('Aucune photo dans les souvenirs choisis.',
                      style: TextStyle(color: AppColors.textMedium)))
              : CustomScrollView(
                  slivers: [
                    const SliverPadding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                      sliver: SliverToBoxAdapter(
                        child: Text(
                          'Touche une photo pour la voir en grand. '
                          'Touche ☆ pour qu\'elle occupe une page entière '
                          'dans le livre.',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textMedium),
                        ),
                      ),
                    ),
                    for (final m in withPhotos) ...[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                        sliver: SliverToBoxAdapter(
                          child: Text.rich(TextSpan(children: [
                            TextSpan(
                                text: (m.title?.isNotEmpty ?? false) ? m.title! : 'Souvenir',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textDark,
                                    fontSize: 14)),
                            TextSpan(
                                text: '  ·  ${dateFmt.format(m.date)}',
                                style: const TextStyle(
                                    color: AppColors.textMedium,
                                    fontSize: 12)),
                          ])),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _featuredCount == 0
                    ? 'Aucune photo en grand'
                    : '$_featuredCount photo${_featuredCount > 1 ? 's' : ''} '
                        'en grand · +$_featuredCount page${_featuredCount > 1 ? 's' : ''} '
                        'environ',
                style: const TextStyle(
                    color: AppColors.textMedium, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving || _loading ? null : _save,
                  child: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
