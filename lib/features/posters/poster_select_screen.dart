import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/models/poster_template.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/tag_service.dart';
import '../tags/tag_picker_sheet.dart';

/// Choix des photos qui composeront le tirage à accrocher — équivalent
/// poster de MemorySelectScreen, volontairement plus léger (pas de mesures
/// croissance, pas de "tout cocher par défaut" : une sélection délibérée,
/// plafonnée à `posterMaxPhotos` PHOTOS (pas souvenirs) au total.
///
/// Un souvenir avec plusieurs photos ouvre une sheet pour choisir laquelle
/// (ou lesquelles) inclure — pas de choix automatique de "la première photo".
class PosterSelectScreen extends StatefulWidget {
  final String? editOrderId;
  const PosterSelectScreen({super.key, this.editOrderId});

  @override
  State<PosterSelectScreen> createState() => _PosterSelectScreenState();
}

typedef _PhotoRef = ({String memoryId, int photoIndex});

class _PosterSelectScreenState extends State<PosterSelectScreen> {
  final Set<String> _filterLabels = {};
  // Ordre de sélection préservé (importe pour le collage : la 1ʳᵉ photo
  // cochée est celle proposée "en vedette" par défaut).
  final List<_PhotoRef> _selected = [];
  List<TagModel> _tags = [];
  List<MemoryModel> _all = [];
  StreamSubscription? _tagsSub;
  StreamSubscription? _memSub;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tagsSub = TagService.streamMine().listen((tags) {
      if (!mounted) return;
      setState(() => _tags = tags);
    });
    _memSub = MemoryQueryService.visible().listen((memories) {
      if (!mounted) return;
      setState(() {
        _all = memories;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _tagsSub?.cancel();
    _memSub?.cancel();
    super.dispose();
  }

  List<TagModel> get _selectedTags =>
      [for (final t in _tags) if (_filterLabels.contains(t.label)) t];

  bool _hasPhoto(MemoryModel m) =>
      m.mediaKeys.isNotEmpty ||
      m.mediaUrls.isNotEmpty ||
      (m.photoUrl?.isNotEmpty ?? false);

  List<MemoryModel> get _visible => _all
      .where((m) => m.type != 'taille_poids')
      .where(_hasPhoto)
      .where((m) => memoryMatchesTags(m, _selectedTags))
      .toList();

  Future<void> _openFilter() async {
    final result = await showTagPickerSheet(
      context,
      tags: _tags,
      initialLabels: _filterLabels,
      title: 'Filtrer les photos',
    );
    if (result == null || !mounted) return;
    setState(() {
      _filterLabels
        ..clear()
        ..addAll(result);
    });
  }

  int _selectedCountFor(String memoryId) =>
      _selected.where((e) => e.memoryId == memoryId).length;

  bool _isSelected(String memoryId, int idx) =>
      _selected.any((e) => e.memoryId == memoryId && e.photoIndex == idx);

  /// Coche/décoche une photo précise. Renvoie false (et affiche un message)
  /// si le plafond global est atteint.
  bool _togglePhoto(String memoryId, int idx) {
    final existing =
        _selected.indexWhere((e) => e.memoryId == memoryId && e.photoIndex == idx);
    if (existing >= 0) {
      _selected.removeAt(existing);
      return true;
    }
    if (_selected.length >= posterMaxPhotos) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Maximum $posterMaxPhotos photos pour un tirage — décoche-en une pour en choisir une autre.'),
      ));
      return false;
    }
    _selected.add((memoryId: memoryId, photoIndex: idx));
    return true;
  }

  Future<void> _onRowTap(MemoryModel m) async {
    final urls = await PhotoService.resolvePhotoUrls(m);
    if (!mounted || urls.isEmpty) return;
    if (urls.length == 1) {
      setState(() => _togglePhoto(m.id, 0));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemoryPhotosSheet(
        memory: m,
        urls: urls,
        isSelected: (i) => _isSelected(m.id, i),
        onToggle: (i) => setState(() => _togglePhoto(m.id, i)),
      ),
    );
  }

  void _continue() {
    final photos = _selected.map((e) => '${e.memoryId}:${e.photoIndex}').join(',');
    final editOrder =
        widget.editOrderId != null ? '&editOrder=${widget.editOrderId}' : '';
    context.push('/poster/new?photos=$photos$editOrder');
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Choisir les photos',
          style: TextStyle(
            fontFamily: 'Fraunces',
            fontWeight: FontWeight.w600,
            color: AppColors.textDark,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () => context.go('/home'),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                  child: Row(
                    children: [
                      _Chip(
                        label: _filterLabels.isEmpty
                            ? '⚙ Filtrer par tag'
                            : '⚙ ${_filterLabels.length} tag${_filterLabels.length > 1 ? 's' : ''}',
                        selected: _filterLabels.isNotEmpty,
                        onTap: _openFilter,
                      ),
                      const Spacer(),
                      Text(
                        '${_selected.length} / $posterMaxPhotos photos',
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textMedium,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: visible.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'Aucune photo ici. Choisis un autre tag, ou importe des médias.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: AppColors.textMedium, height: 1.5),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                          itemCount: visible.length,
                          itemBuilder: (_, i) {
                            final m = visible[i];
                            return _PhotoMemoryRow(
                              memory: m,
                              selectedCount: _selectedCountFor(m.id),
                              onTap: () => _onRowTap(m),
                            );
                          },
                        ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: ElevatedButton(
            onPressed: _selected.isEmpty ? null : _continue,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: AppColors.sageDark,
              disabledBackgroundColor: AppColors.softGray.withOpacity(0.3),
            ),
            child: Text(_selected.isEmpty
                ? 'Sélectionne au moins une photo'
                : 'Composer le tirage (${_selected.length})'),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.sageDark : AppColors.surface,
          borderRadius: BorderRadius.circular(50),
          border: Border.all(
            color: selected ? AppColors.sageDark : AppColors.border,
            width: selected ? 1.5 : 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.textMedium,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _PhotoMemoryRow extends StatelessWidget {
  final MemoryModel memory;
  final int selectedCount;
  final VoidCallback onTap;
  const _PhotoMemoryRow({
    required this.memory,
    required this.selectedCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final title = (memory.title?.trim().isNotEmpty ?? false)
        ? memory.title!.trim()
        : (memory.rawContent.trim().isNotEmpty
            ? memory.rawContent.trim()
            : 'Souvenir');
    final date = DateFormat('d MMM yyyy', 'fr').format(memory.date);
    final selected = selectedCount > 0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.sageDark : AppColors.border,
            width: selected ? 1.2 : 0.5,
          ),
        ),
        child: Row(
          children: [
            _CountBadge(count: selectedCount),
            const SizedBox(width: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 64,
                height: 64,
                child: FutureBuilder<List<String>>(
                  future: PhotoService.resolvePhotoUrls(memory),
                  builder: (_, snap) {
                    final photos = snap.data ?? const [];
                    final url = photos.isNotEmpty ? photos.first : null;
                    if (url == null) return Container(color: AppColors.sageTint);
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(color: AppColors.sageTint),
                          errorWidget: (_, __, ___) => Container(color: AppColors.sageTint),
                        ),
                        if (photos.length > 1)
                          Positioned(
                            right: 3,
                            bottom: 3,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.6),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('${photos.length}',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark)),
                  const SizedBox(height: 2),
                  Text(
                    selected
                        ? '$date · $selectedCount photo${selectedCount > 1 ? 's' : ''} choisie${selectedCount > 1 ? 's' : ''}'
                        : date,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMedium),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return const Icon(Icons.circle_outlined,
          color: AppColors.softGray, size: 22);
    }
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
          color: AppColors.sageDark, shape: BoxShape.circle),
      child: Text('$count',
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

/// Sheet listant TOUTES les photos d'un souvenir — s'ouvre quand il en a
/// plusieurs, pour choisir laquelle (ou lesquelles) inclure au lieu de
/// prendre automatiquement la première.
class _MemoryPhotosSheet extends StatelessWidget {
  final MemoryModel memory;
  final List<String> urls;
  final bool Function(int index) isSelected;
  final void Function(int index) onToggle;
  const _MemoryPhotosSheet({
    required this.memory,
    required this.urls,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final title = (memory.title?.trim().isNotEmpty ?? false)
        ? memory.title!.trim()
        : 'Souvenir';
    return StatefulBuilder(
      builder: (context, setModalState) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontFamily: 'PlayfairDisplay',
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark)),
                const SizedBox(height: 4),
                const Text(
                  'Tape une ou plusieurs photos à inclure dans le tirage.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textMedium),
                ),
                const SizedBox(height: 14),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: urls.length,
                  itemBuilder: (_, i) {
                    final selected = isSelected(i);
                    return GestureDetector(
                      onTap: () {
                        onToggle(i);
                        setModalState(() {});
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CachedNetworkImage(
                              imageUrl: urls[i],
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(color: AppColors.sageTint),
                              errorWidget: (_, __, ___) => Container(color: AppColors.sageTint),
                            ),
                            if (selected)
                              Container(
                                color: AppColors.sageDark.withOpacity(0.35),
                                alignment: Alignment.center,
                                child: const Icon(Icons.check_circle,
                                    color: Colors.white, size: 28),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: const Text('OK'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
