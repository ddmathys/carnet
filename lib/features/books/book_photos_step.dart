import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../../core/models/book_draft.dart';
import '../../core/models/memory_model.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/media_fullscreen_viewer.dart';
import 'featured_photos.dart';

// ── Étape « Photos » du parcours livre (22.10.26) ───────────────────────────
// Trois options, chacune ouverte en plein écran puis validée : les photos en
// grand, les photos à retirer, la couverture. Avant, c'étaient deux étapes
// séparées (« Photos en grand », « Couverture ») et le retrait d'une photo
// n'existait que dans l'aperçu.

/// Photos d'un souvenir, dans l'ordre des pages : identifiant stable → URL.
class BookPhotoGroup {
  final MemoryModel memory;
  final Map<String, String> photos;
  const BookPhotoGroup(this.memory, this.photos);
}

/// Charge les photos des souvenirs du livre (concurrence bornée : un livre
/// peut compter des dizaines de souvenirs).
Future<List<BookPhotoGroup>> loadBookPhotoGroups(
    List<MemoryModel> memories) async {
  final sorted = memories.where((m) => m.type != 'taille_poids').toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final photos = <String, Map<String, String>>{};
  var next = 0;
  Future<void> worker() async {
    while (next < sorted.length) {
      final m = sorted[next++];
      try {
        photos[m.id] = await loadFeaturablePhotos(m);
      } catch (_) {
        photos[m.id] = const {};
      }
    }
  }

  await Future.wait(List.generate(4, (_) => worker()));
  return [
    for (final m in sorted)
      if ((photos[m.id] ?? const {}).isNotEmpty)
        BookPhotoGroup(m, photos[m.id]!),
  ];
}

enum BookPhotoOption { featured, remove, cover }

/// Ce que l'écran de choix lit et modifie chez le parcours. Les getters sont
/// relus à chaque reconstruction : l'écran reflète toujours l'état du livre.
class BookPhotoChoices {
  final Set<String> Function() excluded;
  final ValueChanged<String> onToggleExcluded;

  /// Photos en grand de CE livre (les souvenirs ne sont pas touchés).
  final Set<String> Function() featured;
  final ValueChanged<String> onToggleFeatured;
  final String? Function() coverId;
  final String? Function() backCoverId;
  final void Function(String? id, String? url) onSetCover;
  final void Function(String? id, String? url) onSetBackCover;
  final bool Function() excludeCoverFromBook;
  final ValueChanged<bool> onExcludeCoverFromBook;

  const BookPhotoChoices({
    required this.excluded,
    required this.onToggleExcluded,
    required this.featured,
    required this.onToggleFeatured,
    required this.coverId,
    required this.backCoverId,
    required this.onSetCover,
    required this.onSetBackCover,
    required this.excludeCoverFromBook,
    required this.onExcludeCoverFromBook,
  });
}

/// Une option ouverte en plein écran : toucher une photo la choisit (ou la
/// retire), la loupe l'ouvre en grand, « Valider » revient à l'étape.
class BookPhotoPickScreen extends StatefulWidget {
  final BookPhotoOption option;
  final List<BookPhotoGroup> groups;
  final BookPhotoChoices choices;

  const BookPhotoPickScreen({
    super.key,
    required this.option,
    required this.groups,
    required this.choices,
  });

  /// Renvoie true quand l'option a été validée.
  static Future<bool> open(
    BuildContext context, {
    required BookPhotoOption option,
    required List<BookPhotoGroup> groups,
    required BookPhotoChoices choices,
  }) async =>
      await Navigator.of(context).push<bool>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => BookPhotoPickScreen(
            option: option, groups: groups, choices: choices),
      )) ??
      false;

  @override
  State<BookPhotoPickScreen> createState() => _BookPhotoPickScreenState();
}

class _BookPhotoPickScreenState extends State<BookPhotoPickScreen> {
  /// Couverture : on choisit le devant (false) ou le dos (true).
  bool _back = false;

  BookPhotoChoices get _c => widget.choices;

  bool _isFeatured(String id) => _c.featured().contains(id);

  int get _featuredCount {
    final ex = _c.excluded();
    var n = 0;
    for (final g in widget.groups) {
      n += g.photos.keys.where((id) => _isFeatured(id) && !ex.contains(id)).length;
    }
    return n;
  }

  void _tap(int g, String id, String url) {
    switch (widget.option) {
      case BookPhotoOption.featured:
        if (_c.excluded().contains(id)) return;
        _c.onToggleFeatured(id);
        setState(() {});
      case BookPhotoOption.remove:
        _c.onToggleExcluded(id);
        setState(() {});
      case BookPhotoOption.cover:
        if (_back) {
          _c.onSetBackCover(_c.backCoverId() == id ? null : id,
              _c.backCoverId() == id ? null : url);
        } else {
          _c.onSetCover(id, url);
        }
        setState(() {});
    }
  }

  bool _isChosen(int g, String id) => switch (widget.option) {
        BookPhotoOption.featured =>
          _isFeatured(id) && !_c.excluded().contains(id),
        BookPhotoOption.remove => _c.excluded().contains(id),
        BookPhotoOption.cover =>
          (_back ? _c.backCoverId() : _c.coverId()) == id,
      };

  void _openViewer(int g0, String id0) {
    final ids = <String>[], urls = <String>[], owners = <int>[];
    var initial = 0;
    for (var g = 0; g < widget.groups.length; g++) {
      for (final e in widget.groups[g].photos.entries) {
        if (g == g0 && e.key == id0) initial = ids.length;
        ids.add(e.key);
        urls.add(e.value);
        owners.add(g);
      }
    }
    MediaFullscreenViewer.open(
      context,
      items: [for (final u in urls) FullscreenMedia.photoUrl(u)],
      initialIndex: initial,
      bottomAction: (i, refresh) {
        final chosen = _isChosen(owners[i], ids[i]);
        return ElevatedButton.icon(
          onPressed: () {
            _tap(owners[i], ids[i], urls[i]);
            refresh();
          },
          icon: Icon(chosen ? Icons.check_circle : _optionIcon, size: 20),
          label: Text(chosen ? _chosenLabel : _chooseLabel),
          style: ElevatedButton.styleFrom(
            backgroundColor: chosen ? _accent : Colors.white,
            foregroundColor: chosen ? Colors.white : AppColors.textDark,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          ),
        );
      },
    );
  }

  Color get _accent => widget.option == BookPhotoOption.remove
      ? AppColors.error
      : AppColors.sage;

  IconData get _optionIcon => switch (widget.option) {
        BookPhotoOption.featured => Icons.star_border,
        BookPhotoOption.remove => Icons.remove_circle_outline,
        BookPhotoOption.cover => Icons.auto_stories_outlined,
      };

  String get _chooseLabel => switch (widget.option) {
        BookPhotoOption.featured => 'Mettre en grand',
        BookPhotoOption.remove => 'Retirer du livre',
        BookPhotoOption.cover => _back ? 'Mettre au dos' : 'En couverture',
      };

  String get _chosenLabel => switch (widget.option) {
        BookPhotoOption.featured => 'En grand',
        BookPhotoOption.remove => 'Retirée du livre',
        BookPhotoOption.cover => _back ? 'Au dos' : 'En couverture',
      };

  String get _title => switch (widget.option) {
        BookPhotoOption.featured => 'Photos en grand',
        BookPhotoOption.remove => 'Photos à retirer',
        BookPhotoOption.cover => 'Couverture',
      };

  String get _help => switch (widget.option) {
        BookPhotoOption.featured =>
          'Touche les photos qui méritent une page entière. La loupe les '
              'ouvre en plein écran.',
        BookPhotoOption.remove =>
          'Touche les photos que tu ne veux PAS dans ce livre. Elles restent '
              'dans tes souvenirs, seul le livre change.',
        BookPhotoOption.cover => _back
            ? 'Facultatif : une photo pour le dos du livre. Touche-la à '
                'nouveau pour l\'enlever.'
            : 'Touche la photo qui fera la couverture.',
      };

  String get _validateLabel {
    switch (widget.option) {
      case BookPhotoOption.featured:
        final n = _featuredCount;
        return n == 0 ? 'Valider · aucune en grand' : 'Valider · $n en grand';
      case BookPhotoOption.remove:
        final n = _c.excluded().length;
        return n == 0
            ? 'Valider · aucune retirée'
            : 'Valider · $n retirée${n > 1 ? 's' : ''}';
      case BookPhotoOption.cover:
        return 'Valider la couverture';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('d MMM yyyy', 'fr');
    final excluded = _c.excluded();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(_title,
            style: const TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.option == BookPhotoOption.cover) ...[
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                            value: false,
                            label: Text('Couverture'),
                            icon: Icon(Icons.auto_stories_outlined)),
                        ButtonSegment(
                            value: true,
                            label: Text('Dos (facultatif)'),
                            icon: Icon(Icons.crop_portrait_outlined)),
                      ],
                      selected: {_back},
                      onSelectionChanged: (s) =>
                          setState(() => _back = s.first),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Text(_help,
                      style: const TextStyle(
                          fontSize: 13.5,
                          color: AppColors.textMedium,
                          height: 1.4)),
                  if (widget.option == BookPhotoOption.cover &&
                      !_back &&
                      _c.coverId() != null)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: AppColors.sage,
                      value: _c.excludeCoverFromBook(),
                      onChanged: (v) {
                        _c.onExcludeCoverFromBook(v ?? false);
                        setState(() {});
                      },
                      title: const Text(
                          'Ne pas répéter cette photo dans les pages',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textDark)),
                    ),
                ],
              ),
            ),
          ),
          for (var g = 0; g < widget.groups.length; g++) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              sliver: SliverToBoxAdapter(
                child: _groupTitle(widget.groups[g].memory, dateFmt),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid.count(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (final e in widget.groups[g].photos.entries)
                    BookPickTile(
                      url: e.value,
                      chosen: _isChosen(g, e.key),
                      accent: _accent,
                      chosenIcon: switch (widget.option) {
                        BookPhotoOption.featured => Icons.star,
                        BookPhotoOption.remove => Icons.close,
                        BookPhotoOption.cover => Icons.check,
                      },
                      // En grand : une photo retirée n'est plus proposée.
                      dimmed: widget.option == BookPhotoOption.featured &&
                          excluded.contains(e.key),
                      onTap: () => _tap(g, e.key, e.value),
                      onZoom: () => _openViewer(g, e.key),
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
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.check),
            label: Text(_validateLabel),
            style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50)),
          ),
        ),
      ),
    );
  }
}

Widget _groupTitle(MemoryModel m, DateFormat dateFmt) => Text.rich(TextSpan(
      children: [
        TextSpan(
            text: (m.title?.isNotEmpty ?? false) ? m.title! : 'Souvenir',
            style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.textDark,
                fontSize: 14)),
        TextSpan(
            text: '  ·  ${dateFmt.format(m.date)}',
            style: const TextStyle(color: AppColors.textMedium, fontSize: 12)),
      ],
    ));

/// Vignette de choix : toucher = choisir, loupe = voir en plein écran.
class BookPickTile extends StatelessWidget {
  final String url;
  final bool chosen;
  final bool dimmed;
  final Color accent;
  final IconData chosenIcon;
  final VoidCallback onTap;
  final VoidCallback? onZoom;

  /// Texte affiché en bas de la vignette (commentaire déjà posé).
  final String? caption;

  const BookPickTile({
    super.key,
    required this.url,
    required this.chosen,
    required this.onTap,
    this.onZoom,
    this.dimmed = false,
    this.accent = AppColors.sage,
    this.chosenIcon = Icons.check,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Opacity(
              opacity: dimmed ? 0.3 : 1,
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
        ),
        if (chosen)
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accent, width: 3),
                color: accent == AppColors.error
                    ? Colors.white.withOpacity(0.45)
                    : null,
              ),
            ),
          ),
        if (caption != null)
          Positioned(
            left: 4,
            right: 4,
            bottom: 4,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(caption!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textDark, height: 1.2)),
              ),
            ),
          ),
        if (chosen)
          Positioned(
            top: 6,
            left: 6,
            child: IgnorePointer(
              child: Container(
                width: 24,
                height: 24,
                decoration:
                    BoxDecoration(color: accent, shape: BoxShape.circle),
                child: Icon(chosenIcon, color: Colors.white, size: 15),
              ),
            ),
          ),
        if (onZoom != null)
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: onZoom,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.zoom_out_map,
                      color: Colors.white, size: 16),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Étape « Commentaires » : toutes les photos qui iront dans le livre ;
/// toucher une photo ouvre l'éditeur de texte ([onEdit]).
class BookCommentsGrid extends StatelessWidget {
  final List<BookPhotoGroup> groups;
  final Set<String> excluded;
  final Map<String, BookPhotoText> texts;
  final void Function(String memoryId, String id, String url) onEdit;

  const BookCommentsGrid({
    super.key,
    required this.groups,
    required this.excluded,
    required this.texts,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('d MMM yyyy', 'fr');
    return SliverMainAxisGroup(
      slivers: [
        for (final g in groups)
          if (g.photos.keys.any((id) => !excluded.contains(id))) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              sliver: SliverToBoxAdapter(child: _groupTitle(g.memory, dateFmt)),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid.count(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (final e in g.photos.entries)
                    if (!excluded.contains(e.key))
                      BookPickTile(
                        url: e.value,
                        chosen: texts.containsKey(e.key),
                        chosenIcon: Icons.chat_bubble,
                        caption: texts[e.key]?.text,
                        onTap: () => onEdit(g.memory.id, e.key, e.value),
                      ),
                ],
              ),
            ),
          ],
      ],
    );
  }
}
