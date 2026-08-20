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

/// Choix des photos qui composeront le poster — équivalent poster de
/// MemorySelectScreen, volontairement plus léger (pas de mesures
/// croissance, pas de "tout cocher par défaut" : un poster est une
/// sélection délibérée, plafonnée à `posterMaxPhotos`).
///
/// Simplification v1 assumée : chaque souvenir choisi contribue SA
/// PREMIÈRE photo au poster (pas de sous-sélecteur si un souvenir en a
/// plusieurs) — cohérent avec le reste de l'app (ex. photo de couverture du
/// livre) et évite un écran de sélection à deux niveaux.
class PosterSelectScreen extends StatefulWidget {
  final String? editOrderId;
  const PosterSelectScreen({super.key, this.editOrderId});

  @override
  State<PosterSelectScreen> createState() => _PosterSelectScreenState();
}

class _PosterSelectScreenState extends State<PosterSelectScreen> {
  final Set<String> _filterLabels = {};
  // Ordre de sélection préservé (importe pour le collage : la 1ʳᵉ photo
  // cochée est celle proposée "en vedette" par défaut).
  final List<String> _selectedOrder = [];
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

  void _toggle(String memoryId) {
    setState(() {
      if (!_selectedOrder.remove(memoryId)) {
        if (_selectedOrder.length >= posterMaxPhotos) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Maximum $posterMaxPhotos photos pour un poster — décoche-en une pour en choisir une autre.'),
          ));
          return;
        }
        _selectedOrder.add(memoryId);
      }
    });
  }

  void _continue() {
    final ids = _selectedOrder.join(',');
    final editOrder =
        widget.editOrderId != null ? '&editOrder=${widget.editOrderId}' : '';
    context.push('/poster/new?memories=$ids$editOrder');
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
                        '${_selectedOrder.length} / $posterMaxPhotos photos',
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
                            final order = _selectedOrder.indexOf(m.id);
                            return _PhotoMemoryRow(
                              memory: m,
                              selected: order >= 0,
                              selectionRank: order >= 0 ? order + 1 : null,
                              onTap: () => _toggle(m.id),
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
            onPressed: _selectedOrder.isEmpty ? null : _continue,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: AppColors.sageDark,
              disabledBackgroundColor: AppColors.softGray.withOpacity(0.3),
            ),
            child: Text(_selectedOrder.isEmpty
                ? 'Sélectionne au moins une photo'
                : 'Composer le poster (${_selectedOrder.length})'),
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
  final bool selected;
  final int? selectionRank;
  final VoidCallback onTap;
  const _PhotoMemoryRow({
    required this.memory,
    required this.selected,
    required this.selectionRank,
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
            _RankBadge(rank: selectionRank),
            const SizedBox(width: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 64,
                height: 64,
                child: FutureBuilder<List<String>>(
                  future: PhotoService.resolvePhotoUrls(memory),
                  builder: (_, snap) {
                    final url = (snap.data?.isNotEmpty ?? false)
                        ? snap.data!.first
                        : null;
                    if (url == null) return Container(color: AppColors.sageTint);
                    return CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.sageTint),
                      errorWidget: (_, __, ___) => Container(color: AppColors.sageTint),
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
                  Text(date,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textMedium)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  final int? rank;
  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) {
    if (rank == null) {
      return const Icon(Icons.circle_outlined,
          color: AppColors.softGray, size: 22);
    }
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
          color: AppColors.sageDark, shape: BoxShape.circle),
      child: Text('$rank',
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}
