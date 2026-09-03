import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/services/media_upload_queue.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/tag_service.dart';
import '../tags/share_tag_sheet.dart';
import '../tags/tag_picker_sheet.dart';
import 'widgets/memory_polaroid.dart';
import 'widgets/delete_memory.dart';

/// Tous les souvenirs visibles, filtrables par tag. Remplace le « journal »
/// d'un carnet : il n'y a plus qu'une seule collection de souvenirs, et les
/// tags en sont les rayons.
class MemoriesListScreen extends StatefulWidget {
  /// Tag pré-sélectionné (arrivée depuis une puce de tag du dashboard).
  final String? initialTagId;
  const MemoriesListScreen({super.key, this.initialTagId});

  @override
  State<MemoriesListScreen> createState() => _MemoriesListScreenState();
}

class _MemoriesListScreenState extends State<MemoriesListScreen> {
  /// Filtre courant : les libellés de tags cochés (multi-sélection).
  final Set<String> _filterLabels = {};
  final _searchController = TextEditingController();
  String _searchQuery = '';
  // Mes tags + ceux qu'on m'a partagés (même principe que home_screen.dart
  // `_allTags`) — avant, cet écran ne listait que `streamMine()` : un
  // collaborateur invité voyait bien les souvenirs partagés dans la grille,
  // mais ne pouvait jamais filtrer dessus ni cocher `initialTagId` à
  // l'arrivée d'un lien de partage (trouvé à l'audit UX du 03.09.26).
  List<TagModel> _myTags = [];
  List<TagModel> _sharedTags = [];
  List<TagModel> get _tags => [..._myTags, ..._sharedTags];
  StreamSubscription? _tagsSub;
  StreamSubscription? _sharedTagsSub;

  @override
  void initState() {
    super.initState();
    _tagsSub = TagService.streamMine().listen((tags) {
      if (!mounted) return;
      setState(() {
        _myTags = tags;
        _applyInitialTag(tags);
      });
    });
    _sharedTagsSub = TagService.streamSharedWithMe().listen((tags) {
      if (!mounted) return;
      setState(() {
        _sharedTags = tags;
        _applyInitialTag(tags);
      });
    });
  }

  // Arrivée depuis un tag précis (partage rejoint, CTA livre) : il est coché
  // d'emblée, mais reste modifiable comme n'importe quel filtre. Le tag peut
  // venir de l'un ou l'autre flux (mien ou partagé) — d'où l'appel depuis les
  // deux listeners.
  void _applyInitialTag(List<TagModel> tags) {
    final initial = widget.initialTagId;
    if (initial == null || _filterLabels.isNotEmpty) return;
    for (final t in tags) {
      if (t.id == initial) _filterLabels.add(t.label);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tagsSub?.cancel();
    _sharedTagsSub?.cancel();
    super.dispose();
  }

  List<TagModel> get _selectedTags =>
      [for (final t in _tags) if (_filterLabels.contains(t.label)) t];

  /// Un seul tag coché → on peut le partager / voir sa croissance depuis l'appbar.
  TagModel? get _soleTag {
    final sel = _selectedTags;
    return sel.length == 1 ? sel.first : null;
  }

  Future<void> _openFilter() async {
    final result = await showTagPickerSheet(
      context,
      tags: _tags,
      initialLabels: _filterLabels,
    );
    if (result == null || !mounted) return;
    setState(() {
      _filterLabels
        ..clear()
        ..addAll(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tag = _soleTag;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          tag?.label ?? 'Mes souvenirs',
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontWeight: FontWeight.w600,
            color: AppColors.textDark,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () => context.go('/home'),
        ),
        actions: [
          // Un tag « enfant » garde sa courbe de croissance.
          if (tag != null && tag.isChild)
            IconButton(
              icon: const Icon(Icons.show_chart, color: AppColors.textDark),
              tooltip: 'Croissance',
              onPressed: () => context.push('/growth/${tag.id}'),
            ),
          // Un ou plusieurs tags cochés → un seul lien les partage tous.
          if (_selectedTags.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.ios_share, color: AppColors.textDark),
              tooltip: _selectedTags.length == 1
                  ? 'Partager ce tag'
                  : 'Partager ces ${_selectedTags.length} tags',
              onPressed: () => showShareTagSheet(context, _selectedTags),
            ),
        ],
      ),
      body: Column(
        children: [
          const _UploadStatusBanner(),
          Expanded(child: _buildMemoriesStream()),
        ],
      ),
    );
  }

  Widget _buildMemoriesStream() {
    return StreamBuilder<List<MemoryModel>>(
        stream: MemoryQueryService.visible(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          // Les mesures taille/poids ne sont pas des souvenirs comme les
          // autres : elles se saisissent et se consultent uniquement depuis
          // la page croissance (/growth/:tagId), pas ici.
          final all =
              snap.data!.where((m) => m.type != 'taille_poids').toList();
          final selected = _selectedTags;
          final tagFiltered =
              all.where((m) => memoryMatchesTags(m, selected)).toList();
          final filtered = _applySearch(tagFiltered);

          return Column(
            children: [
              _buildSearchBar(),
              if (_tags.isNotEmpty) _buildFilterBar(),
              if (tagFiltered.length >= 10)
                _BookCta(count: tagFiltered.length, tagId: _soleTag?.id),
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyState(
                        hasSearch: _searchQuery.trim().isNotEmpty,
                        onClear: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _filterLabels.clear();
                          });
                        },
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 20,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.66,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final m = filtered[i];
                          return MemoryPolaroid(
                            memory: m,
                            cat: _safeCat(m.type),
                            tilt: (i % 2 == 0) ? -0.02 : 0.02,
                            onTap: () => context.push('/memory/${m.id}'),
                            onDelete: () => confirmAndDeleteMemory(context, m),
                          );
                        },
                      ),
              ),
            ],
          );
        });
  }

  /// Même filtre que le dashboard : un bouton qui ouvre le sélecteur par
  /// catégories (Date / Lieu / Événement), et le rappel des tags cochés.
  Widget _buildFilterBar() {
    final selected = _filterLabels.toList()..sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _FilterChip(
                label: _filterLabels.isEmpty
                    ? '⚙ Filtrer par tag'
                    : '⚙ ${_filterLabels.length} tag${_filterLabels.length > 1 ? 's' : ''}',
                selected: _filterLabels.isNotEmpty,
                onTap: _openFilter,
              ),
              if (_filterLabels.isNotEmpty)
                TextButton(
                  onPressed: () => setState(_filterLabels.clear),
                  child: const Text('Effacer',
                      style:
                          TextStyle(color: AppColors.textMedium, fontSize: 13)),
                ),
            ],
          ),
          if (selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final label in selected)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.sageTint,
                        borderRadius: BorderRadius.circular(50),
                      ),
                      child: Text(label,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.sageDark,
                              fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _searchQuery = v),
        style: const TextStyle(fontSize: 14, color: AppColors.textDark),
        decoration: InputDecoration(
          hintText: 'Lieu (3 lettres min.) ou date…',
          hintStyle: const TextStyle(fontSize: 13, color: AppColors.softGray),
          prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.softGray),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18, color: AppColors.softGray),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: AppColors.border, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: AppColors.border, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: AppColors.sage, width: 1.5),
          ),
        ),
      ),
    );
  }

  // Strip accents and lowercase — "Genève" → "geneve", "île" → "ile"
  String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[àáâãä]'), 'a')
      .replaceAll(RegExp(r'[èéêë]'), 'e')
      .replaceAll(RegExp(r'[ìíîï]'), 'i')
      .replaceAll(RegExp(r'[òóôõö]'), 'o')
      .replaceAll(RegExp(r'[ùúûü]'), 'u')
      .replaceAll('ç', 'c')
      .replaceAll('ñ', 'n')
      .replaceAll('æ', 'ae')
      .replaceAll('œ', 'oe');

  List<MemoryModel> _applySearch(List<MemoryModel> memories) {
    final q = _norm(_searchQuery.trim());
    if (q.isEmpty) return memories;

    return memories.where((m) {
      if (_matchesDate(m, q)) return true;
      if (q.length >= 3) {
        if (_norm(m.location ?? '').contains(q)) return true;
      }
      return false;
    }).toList();
  }

  bool _matchesDate(MemoryModel m, String normalizedQ) {
    try {
      final d = m.date;
      final checks = [
        DateFormat('dd/MM/yyyy').format(d),
        DateFormat('dd/MM').format(d),
        DateFormat('MM/yyyy').format(d),
        DateFormat('yyyy').format(d),
        _norm(DateFormat('MMMM', 'fr').format(d)),
        _norm(DateFormat('MMMM yyyy', 'fr').format(d)),
      ];
      return checks.any((f) => f.contains(normalizedQ));
    } catch (_) {
      return false;
    }
  }

  MilestoneCategory? _safeCat(String type) {
    try {
      return getMilestoneCategoryById(type);
    } catch (_) {
      return null;
    }
  }

}

/// Bannière discrète reflétant la file d'upload en arrière-plan :
/// « Envoi en cours… » avec un petit spinner pendant que les photos/mémos
/// partent, ou une bannière d'erreur avec « Réessayer » si un envoi a échoué.
/// Disparaît une fois tout terminé (la photo apparaît seule via le flux live).
class _UploadStatusBanner extends StatelessWidget {
  const _UploadStatusBanner();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MediaUploadQueue.instance,
      builder: (context, _) {
        final q = MediaUploadQueue.instance;
        if (q.pending > 0) {
          final n = q.pending;
          final vp = q.videoProgress; // null si aucune vidéo en cours
          final pct = vp != null ? (vp * 100).round() : null;
          final title = q.videoTotal > 1
              ? 'Envoi de la vidéo ${q.videoIndex}/${q.videoTotal}…'
              : (vp != null
                  ? 'Envoi de la vidéo…'
                  : (n == 1
                      ? 'Envoi du souvenir en cours…'
                      : 'Envoi de $n souvenirs en cours…'));
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
                    // Déterminée pendant l'envoi d'une vidéo, indéterminée sinon
                    // (photos/mémo, dont on ne suit pas le détail).
                    value: vp,
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

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.sage : AppColors.surface,
          borderRadius: BorderRadius.circular(50),
          border: Border.all(
            color: selected ? AppColors.sage : AppColors.border,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.white : AppColors.textMedium,
          ),
        ),
      ),
    );
  }
}

class _BookCta extends StatelessWidget {
  final int count;
  final String? tagId;
  const _BookCta({required this.count, this.tagId});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context
          .push('/book/select${tagId != null ? '?tag=$tagId' : ''}'),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.amber.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Text('📖', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$count souvenirs — Générer le livre',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.amber,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.amber, size: 18),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasSearch;
  final VoidCallback onClear;
  const _EmptyState({required this.hasSearch, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🔍', style: TextStyle(fontSize: 36)),
          const SizedBox(height: 12),
          Text(
            hasSearch
                ? 'Aucun souvenir trouvé.'
                : 'Aucun souvenir dans ce filtre.',
            style: const TextStyle(color: AppColors.textMedium),
          ),
          if (hasSearch) ...[
            const SizedBox(height: 4),
            const Text(
              'Essaie un lieu (3 lettres min.) ou une date\nex : Paris · 06/2025 · juin',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.softGray),
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: onClear,
            child: const Text('Effacer la recherche',
                style: TextStyle(color: AppColors.sage)),
          ),
        ],
      ),
    );
  }
}
