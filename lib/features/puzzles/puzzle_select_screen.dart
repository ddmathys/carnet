import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/photo_service.dart';

/// Choix de LA photo du puzzle — équivalent poster de PosterSelectScreen,
/// simplifié : un puzzle est une seule photo (pas de collage), donc
/// sélection unique. Un souvenir avec plusieurs photos ouvre une sheet pour
/// choisir laquelle.
class PuzzleSelectScreen extends StatefulWidget {
  const PuzzleSelectScreen({super.key});

  @override
  State<PuzzleSelectScreen> createState() => _PuzzleSelectScreenState();
}

class _PuzzleSelectScreenState extends State<PuzzleSelectScreen> {
  List<MemoryModel> _all = [];
  StreamSubscription? _memSub;
  bool _loading = true;
  String? _selectedMemoryId;
  int? _selectedPhotoIndex;

  @override
  void initState() {
    super.initState();
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
    _memSub?.cancel();
    super.dispose();
  }

  bool _hasPhoto(MemoryModel m) =>
      m.mediaKeys.isNotEmpty ||
      m.mediaUrls.isNotEmpty ||
      (m.photoUrl?.isNotEmpty ?? false);

  List<MemoryModel> get _visible =>
      _all.where((m) => m.type != 'taille_poids').where(_hasPhoto).toList();

  Future<void> _onRowTap(MemoryModel m) async {
    final urls = await PhotoService.resolvePhotoUrls(m);
    if (!mounted || urls.isEmpty) return;

    if (urls.length == 1) {
      setState(() {
        _selectedMemoryId = m.id;
        _selectedPhotoIndex = 0;
      });
      return;
    }

    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemoryPhotosSheet(memory: m, urls: urls),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedMemoryId = m.id;
        _selectedPhotoIndex = picked;
      });
    }
  }

  void _continue() {
    if (_selectedMemoryId == null || _selectedPhotoIndex == null) return;
    context.push(
        '/puzzle/new?memory=$_selectedMemoryId&photo=$_selectedPhotoIndex');
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
          'Choisir la photo',
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Text(
                    'Une seule photo par puzzle — Prodigi la recadre lui-même pour remplir le puzzle et le couvercle de la boîte.',
                    style: TextStyle(
                        fontSize: 11.5, color: AppColors.textMedium, height: 1.3),
                  ),
                ),
                Expanded(
                  child: visible.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'Aucune photo ici. Importe des médias d\'abord.',
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
                              selected: _selectedMemoryId == m.id,
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
            onPressed: _selectedMemoryId == null ? null : _continue,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: AppColors.sageDark,
              disabledBackgroundColor: AppColors.softGray.withOpacity(0.3),
            ),
            child: Text(_selectedMemoryId == null
                ? 'Choisis une photo'
                : 'Composer le puzzle'),
          ),
        ),
      ),
    );
  }
}

class _PhotoMemoryRow extends StatelessWidget {
  final MemoryModel memory;
  final bool selected;
  final VoidCallback onTap;
  const _PhotoMemoryRow({
    required this.memory,
    required this.selected,
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
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected ? AppColors.sageDark : AppColors.softGray,
              size: 22,
            ),
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

/// Sheet listant TOUTES les photos d'un souvenir — s'ouvre quand il en a
/// plusieurs, pour choisir LAQUELLE devient le puzzle (sélection unique,
/// contrairement à la même sheet côté poster qui coche plusieurs photos).
class _MemoryPhotosSheet extends StatelessWidget {
  final MemoryModel memory;
  final List<String> urls;
  const _MemoryPhotosSheet({required this.memory, required this.urls});

  @override
  Widget build(BuildContext context) {
    final title = (memory.title?.trim().isNotEmpty ?? false)
        ? memory.title!.trim()
        : 'Souvenir';
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            decoration: const BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontFamily: 'PlayfairDisplay',
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark)),
                const SizedBox(height: 4),
                Text('Choisis la photo du puzzle (${urls.length} photos).',
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.textMedium)),
                const SizedBox(height: 14),
                Expanded(
                  child: GridView.builder(
                    controller: scrollController,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: urls.length,
                    itemBuilder: (_, i) {
                      return GestureDetector(
                        onTap: () => Navigator.of(context).pop(i),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: CachedNetworkImage(
                            imageUrl: urls[i],
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(color: AppColors.sageTint),
                            errorWidget: (_, __, ___) => Container(color: AppColors.sageTint),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }
}
