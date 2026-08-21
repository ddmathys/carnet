import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/quota_service.dart';
import '../milestones/widgets/growth_multi_chart.dart';

// ── Memory selection bottom sheet ─────────────────────────────────────────────

class MemorySelectionSheet extends StatefulWidget {
  final List<MemoryModel> memories;
  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onChanged;
  final ValueChanged<MemoryModel> onMemoryUpdated;
  // Chapitres croissance : un par enfant, représentés ici comme des cartes à
  // part (pas une ligne « souvenir » comme les autres — voir
  // _visibleMemories) puisqu'ils ne correspondent à aucun souvenir individuel
  // mais à une page récap générée à partir des mesures taille/poids DE CET
  // ENFANT (childTag.id présent dans les tagIds des mesures).
  final List<({TagModel child, List<MemoryModel> measures})> growthGroups;
  final Set<String> excludedGrowthChildIds;
  final ValueChanged<Set<String>> onGrowthChildrenChanged;

  const MemorySelectionSheet({
    super.key,
    required this.memories,
    required this.selectedIds,
    required this.onChanged,
    required this.onMemoryUpdated,
    required this.growthGroups,
    required this.excludedGrowthChildIds,
    required this.onGrowthChildrenChanged,
  });

  @override
  State<MemorySelectionSheet> createState() => _MemorySelectionSheetState();
}

class _MemorySelectionSheetState extends State<MemorySelectionSheet> {
  late Set<String> _local;
  late Set<String> _excludedGrowth;
  // Souvenirs patchés localement après ajout de photos (mediaKeys à jour) —
  // widget.memories n'est reçu qu'une fois à l'ouverture de la sheet, donc on
  // superpose ces versions pour que le compteur/bouton "Mise en page" reflètent
  // les ajouts sans devoir fermer/rouvrir la sheet.
  final Map<String, MemoryModel> _patched = {};
  final Set<String> _uploadingIds = {};

  @override
  void initState() {
    super.initState();
    _local = Set.from(widget.selectedIds);
    _excludedGrowth = Set.from(widget.excludedGrowthChildIds);
  }

  // Les mesures taille/poids ne sont pas des souvenirs qu'on coche/décoche
  // une par une ici — seules les cartes "Courbe de croissance" (une par
  // enfant) représentent ce chapitre. Elles restent dans `_local` (jamais
  // retirées par « Tout cocher/décocher », qui n'agit que sur cette liste
  // visible) pour continuer d'alimenter les courbes même invisibles ici.
  List<MemoryModel> get _visibleMemories =>
      widget.memories.where((m) => m.type != 'taille_poids').toList();

  // Aperçu d'un groupe : montre la taille par défaut, le poids seulement si
  // c'est la mesure la mieux renseignée (plus de points) — évite un aperçu
  // vide si le parent n'a saisi que le poids.
  bool _growthShowWeight(List<MemoryModel> measures) {
    final heights = measures.where((m) => m.heightCm != null).length;
    final weights = measures.where((m) => m.weightKg != null).length;
    return weights > heights;
  }

  MemoryModel _memoryAt(int i) {
    final m = _visibleMemories[i];
    return _patched[m.id] ?? m;
  }

  Future<void> _addPhotosTo(MemoryModel m) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.softGray.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.perm_media_outlined,
                  color: AppColors.sage),
              title: const Text('Choisir dans la galerie'),
              subtitle: const Text('Plusieurs photos à la fois'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading:
                  const Icon(Icons.add_a_photo_outlined, color: AppColors.sage),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picker = ImagePicker();
    List<XFile> picked;
    try {
      if (source == ImageSource.gallery) {
        picked = await picker.pickMultiImage(imageQuality: 80, maxWidth: 1920);
      } else {
        final shot = await picker.pickImage(
            source: ImageSource.camera, imageQuality: 80, maxWidth: 1920);
        picked = shot != null ? [shot] : const [];
      }
    } catch (_) {
      if (mounted) _showSnack('Impossible d\'accéder à la photo');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final q = await QuotaService.canAddPhotos(uid, adding: picked.length);
      if (!q.allowed) {
        if (mounted) {
          _showSnack(
              'Limite de ${q.limit} photos atteinte — retire des photos avant d\'en ajouter.');
        }
        return;
      }
    }

    setState(() => _uploadingIds.add(m.id));
    try {
      final files = picked.map((x) => File(x.path)).toList();
      final newKeys = await PhotoService.uploadMultiplePhotosToR2(
        photos: files,
        notebookId: m.notebookId,
      );
      if (newKeys.length < files.length && mounted) {
        _showSnack(
            '${files.length - newKeys.length} photo(s) n\'ont pas pu être envoyées.');
      }
      if (newKeys.isEmpty) return;

      final allKeys = [...m.mediaKeys, ...newKeys];
      await FirebaseFirestore.instance
          .collection('memories')
          .doc(m.id)
          .update({'mediaKeys': allKeys});
      PhotoService.invalidateSignedCache(m.id);

      final updated = m.copyWith(mediaKeys: allKeys);
      if (mounted) setState(() => _patched[m.id] = updated);
      widget.onMemoryUpdated(updated);
    } catch (e) {
      if (mounted) _showSnack('Échec de l\'envoi : $e');
    } finally {
      if (mounted) setState(() => _uploadingIds.remove(m.id));
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _formatDate(MemoryModel m) {
    if (m.dateLabel != null) return m.dateLabel!;
    final d = m.date;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _typeLabel(String type) => switch (type) {
        'anecdote' => 'Anecdote',
        'growth' => 'Croissance',
        'event' => 'Événement',
        'milestone' => 'Étape',
        'travel' => 'Voyage',
        'health' => 'Santé',
        _ => type,
      };

  int get _photoCount {
    int n = 0;
    for (final id in _local) {
      final m = widget.memories
          .firstWhere((m) => m.id == id, orElse: () => widget.memories.first);
      if (m.mediaKeys.isNotEmpty || m.mediaUrls.isNotEmpty) {
        n += m.mediaKeys.length + m.mediaUrls.length;
      } else if (m.photoUrl != null && m.photoUrl!.isNotEmpty) {
        n++;
      }
    }
    return n;
  }

  // Nombre de souvenirs VISIBLES cochés — exclut les mesures taille/poids
  // (jamais montrées ici, cf. _visibleMemories), pour que le compteur affiché
  // corresponde à ce que l'utilisateur voit et coche dans cette liste.
  int get _visibleSelectedCount {
    final visibleIds = _visibleMemories.map((m) => m.id).toSet();
    return _local.where(visibleIds.contains).length;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      maxChildSize: 0.96,
      minChildSize: 0.5,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.softGray.withOpacity(0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  const Text(
                    'Souvenirs à inclure',
                    style: TextStyle(
                      fontFamily: 'PlayfairDisplay',
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero, minimumSize: Size.zero),
                    onPressed: () => setState(() {
                      final visibleIds =
                          _visibleMemories.map((m) => m.id).toSet();
                      if (visibleIds.every(_local.contains)) {
                        _local.removeAll(visibleIds);
                      } else {
                        _local.addAll(visibleIds);
                      }
                    }),
                    child: Text(
                      _visibleMemories.isNotEmpty &&
                              _visibleMemories
                                  .every((m) => _local.contains(m.id))
                          ? 'Tout décocher'
                          : 'Tout cocher',
                      style:
                          const TextStyle(color: AppColors.sage, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFEEEBE3)),
            for (final g in widget.growthGroups)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() {
                    if (!_excludedGrowth.remove(g.child.id)) {
                      _excludedGrowth.add(g.child.id);
                    }
                  }),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.sageTint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: !_excludedGrowth.contains(g.child.id)
                                ? AppColors.sage
                                : AppColors.surface,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: !_excludedGrowth.contains(g.child.id)
                                  ? AppColors.sage
                                  : const Color(0xFFCCC8BE),
                              width: 1.5,
                            ),
                          ),
                          child: !_excludedGrowth.contains(g.child.id)
                              ? const Icon(Icons.check,
                                  size: 14, color: Colors.white)
                              : null,
                        ),
                        const SizedBox(width: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 84,
                            height: 56,
                            color: AppColors.surface,
                            padding: const EdgeInsets.all(4),
                            child: GrowthMultiChart(
                              notebook: g.child.asNotebook(),
                              measures: g.measures,
                              showWeight: _growthShowWeight(g.measures),
                              compact: true,
                              chartHeight: 48,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Courbe de croissance — ${g.child.label}',
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textDark),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                'Générée depuis les mesures de la page '
                                'Croissance — occupe une pleine page A4 dans '
                                'le livre.',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: AppColors.textMedium,
                                    height: 1.3),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (widget.growthGroups.isNotEmpty) const SizedBox(height: 4),
            // Memory list
            Expanded(
              child: ListView.builder(
                controller: ctrl,
                itemCount: _visibleMemories.length,
                itemBuilder: (_, i) {
                  final m = _memoryAt(i);
                  final selected = _local.contains(m.id);
                  final uploading = _uploadingIds.contains(m.id);
                  final hasR2OrLegacyMedia =
                      m.mediaKeys.isNotEmpty || m.mediaUrls.isNotEmpty;
                  final hasPhotos = hasR2OrLegacyMedia ||
                      (m.photoUrl != null && m.photoUrl!.isNotEmpty);
                  final photoCount = hasR2OrLegacyMedia
                      ? m.mediaKeys.length + m.mediaUrls.length
                      : (hasPhotos ? 1 : 0);
                  final preview = m.rawContent.length > 65
                      ? '${m.rawContent.substring(0, 65)}…'
                      : m.rawContent;

                  return InkWell(
                    onTap: () => setState(() {
                      selected ? _local.remove(m.id) : _local.add(m.id);
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Checkbox
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color:
                                  selected ? AppColors.sage : AppColors.surface,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: selected
                                    ? AppColors.sage
                                    : const Color(0xFFCCC8BE),
                                width: 1.5,
                              ),
                            ),
                            child: selected
                                ? const Icon(Icons.check,
                                    size: 14, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(width: 12),
                          // Content
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      _formatDate(m),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: selected
                                            ? AppColors.sage
                                            : AppColors.textMedium,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.background,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        _typeLabel(m.type),
                                        style: const TextStyle(
                                            fontSize: 10,
                                            color: AppColors.textMedium),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  preview,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: selected
                                        ? AppColors.textDark
                                        : AppColors.textMedium,
                                    height: 1.4,
                                  ),
                                ),
                                if (hasPhotos) ...[
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(Icons.photo_outlined,
                                          size: 12,
                                          color:
                                              AppColors.sage.withOpacity(0.8)),
                                      const SizedBox(width: 3),
                                      Text(
                                        '$photoCount photo${photoCount > 1 ? 's' : ''}',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: AppColors.sage
                                                .withOpacity(0.8)),
                                      ),
                                    ],
                                  ),
                                ],
                                if (selected) ...[
                                  const SizedBox(height: 6),
                                  GestureDetector(
                                    onTap: uploading
                                        ? null
                                        : () => _addPhotosTo(m),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: AppColors.background,
                                        borderRadius:
                                            BorderRadius.circular(8),
                                        border: Border.all(
                                            color: AppColors.sage
                                                .withOpacity(0.4)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (uploading)
                                            const SizedBox(
                                                width: 12,
                                                height: 12,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 1.5))
                                          else
                                            const Icon(Icons.add_photo_alternate_outlined,
                                                size: 13,
                                                color: AppColors.sage),
                                          const SizedBox(width: 4),
                                          Text(
                                            uploading
                                                ? 'Envoi en cours…'
                                                : 'Ajouter des photos',
                                            style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.sage
                                                    .withOpacity(0.9)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                if (selected && hasPhotos) ...[
                                  const SizedBox(height: 6),
                                  GestureDetector(
                                    onTap: () async {
                                      final updated = await showModalBottomSheet<
                                          MemoryModel>(
                                        context: context,
                                        isScrollControlled: true,
                                        backgroundColor: Colors.transparent,
                                        builder: (_) =>
                                            MemoryLayoutSheet(memory: m),
                                      );
                                      if (updated != null) {
                                        widget.onMemoryUpdated(updated);
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: AppColors.sageTint,
                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.tune,
                                              size: 13, color: AppColors.sage),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Mise en page · densité, photos en grand',
                                            style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.sage
                                                    .withOpacity(0.9)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Choisis jusqu\'à 3 photos à imprimer en '
                                    'grand (pleine page)',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        color: AppColors.textMedium
                                            .withOpacity(0.85)),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1, color: Color(0xFFEEEBE3)),
            // Confirm button
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 12, 20, 12 + MediaQuery.of(context).padding.bottom),
              child: Column(
                children: [
                  Text(
                    '$_visibleSelectedCount souvenir${_visibleSelectedCount != 1 ? 's' : ''} · $_photoCount photo${_photoCount != 1 ? 's' : ''}',
                    style: const TextStyle(
                        color: AppColors.textMedium, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _visibleSelectedCount == 0 &&
                              widget.growthGroups.every(
                                  (g) => _excludedGrowth.contains(g.child.id))
                          ? null
                          : () {
                              widget.onChanged(Set.from(_local));
                              widget.onGrowthChildrenChanged(
                                  Set.from(_excludedGrowth));
                              Navigator.pop(context);
                            },
                      child: Text(
                          'Confirmer ($_visibleSelectedCount/${_visibleMemories.length})'),
                    ),
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

/// Réglages de mise en page pour UN souvenir : densité verticale/horizontale
/// (2 ou 4 photos/page) et photos "en grand" (pleine page dans le livre,
/// nombre illimité — chacune devient sa propre page). Sauvegarde directe sur
/// Firestore ; renvoie le MemoryModel à jour (via `Navigator.pop`) pour que
/// l'appelant patche son état local.
class MemoryLayoutSheet extends StatefulWidget {
  final MemoryModel memory;
  const MemoryLayoutSheet({super.key, required this.memory});

  @override
  State<MemoryLayoutSheet> createState() => _MemoryLayoutSheetState();
}

class _MemoryLayoutSheetState extends State<MemoryLayoutSheet> {
  late int _vDensity = widget.memory.bookVerticalDensity;
  late int _hDensity = widget.memory.bookHorizontalDensity;
  final Set<String> _featured = {};
  Map<String, String>? _thumbs; // rawId -> URL affichable
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _featured.addAll(widget.memory.bookFeaturedMedia);
    _loadThumbs();
  }

  // Miroir de PhotoService.resolvePhotoUrls (R2 signées d'abord, puis legacy)
  // mais en conservant l'identifiant STABLE (clé ou URL) comme clé de map —
  // c'est cet identifiant qui est stocké dans bookFeaturedMedia et comparé
  // côté génération PDF (book_pdf_service.dart::rawMediaIdsOf).
  Future<void> _loadThumbs() async {
    final m = widget.memory;
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
    if (mounted) setState(() => _thumbs = map);
  }

  void _toggleFeatured(String rawId) {
    setState(() {
      if (_featured.contains(rawId)) {
        _featured.remove(rawId);
      } else {
        _featured.add(rawId);
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final updated = widget.memory.copyWith(
      bookVerticalDensity: _vDensity,
      bookHorizontalDensity: _hDensity,
      bookFeaturedMedia: _featured.toList(),
    );
    try {
      await FirebaseFirestore.instance
          .collection('memories')
          .doc(widget.memory.id)
          .update({
        'bookVerticalDensity': _vDensity,
        'bookHorizontalDensity': _hDensity,
        'bookFeaturedMedia': _featured.toList(),
      });
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

  Widget _densityChoice(
      String label, int value, ValueChanged<int> onChanged) {
    Widget pill(int v) {
      final sel = value == v;
      return GestureDetector(
        onTap: () => onChanged(v),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: sel ? AppColors.sage : AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: sel ? AppColors.sage : const Color(0xFFCCC8BE)),
          ),
          child: Text('$v / page',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: sel ? Colors.white : AppColors.textMedium,
              )),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 8),
        Row(children: [pill(2), const SizedBox(width: 10), pill(4)]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      minChildSize: 0.5,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.softGray.withOpacity(0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Mise en page du souvenir',
                  style: TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: ctrl,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: [
                  _densityChoice('Photos verticales', _vDensity,
                      (v) => setState(() => _vDensity = v)),
                  const SizedBox(height: 18),
                  _densityChoice('Photos horizontales', _hDensity,
                      (v) => setState(() => _hDensity = v)),
                  const SizedBox(height: 22),
                  Text(
                    'Photos en grand (${_featured.length})',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Touche une photo pour qu\'elle occupe une page entière dans le livre.',
                    style:
                        TextStyle(fontSize: 12, color: AppColors.textMedium),
                  ),
                  const SizedBox(height: 10),
                  if (_thumbs == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 30),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_thumbs!.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('Aucune photo sur ce souvenir.',
                          style: TextStyle(color: AppColors.textMedium)),
                    )
                  else
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                      children: [
                        for (final entry in _thumbs!.entries)
                          GestureDetector(
                            onTap: () => _toggleFeatured(entry.key),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: CachedNetworkImage(
                                    imageUrl: entry.value,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                if (_featured.contains(entry.key))
                                  Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                          color: AppColors.sage, width: 3),
                                      color:
                                          AppColors.sage.withOpacity(0.15),
                                    ),
                                    child: const Align(
                                      alignment: Alignment.topRight,
                                      child: Padding(
                                        padding: EdgeInsets.all(4),
                                        child: Icon(Icons.star,
                                            color: AppColors.sage, size: 18),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFEEEBE3)),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 12, 20, 12 + MediaQuery.of(context).padding.bottom),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
