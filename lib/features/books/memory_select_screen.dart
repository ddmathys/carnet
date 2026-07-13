import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/tag_service.dart';

/// Choix des souvenirs qui composeront le livre.
///
/// Deux façons de choisir, combinables : filtrer par tag (et tout prendre d'un
/// coup), ou cocher les souvenirs un par un. Remplace l'ancien choix de carnets.
class MemorySelectScreen extends StatefulWidget {
  final String? initialTagId;
  const MemorySelectScreen({super.key, this.initialTagId});

  @override
  State<MemorySelectScreen> createState() => _MemorySelectScreenState();
}

class _MemorySelectScreenState extends State<MemorySelectScreen> {
  String? _tagId;
  final Set<String> _selected = {};
  List<TagModel> _tags = [];
  List<MemoryModel> _all = [];
  StreamSubscription? _tagsSub;
  StreamSubscription? _memSub;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tagId = widget.initialTagId;
    _tagsSub = TagService.streamMine().listen((tags) {
      if (mounted) setState(() => _tags = tags);
    });
    _memSub = MemoryQueryService.visible().listen((memories) {
      if (!mounted) return;
      setState(() {
        _all = memories;
        _loading = false;
        // Premier chargement : tout ce qui correspond au filtre est retenu —
        // on décoche plutôt qu'on ne coche (le cas courant est « tout le tag »).
        if (_selected.isEmpty) {
          _selected.addAll(_visible.map((m) => m.id));
        }
      });
    });
  }

  @override
  void dispose() {
    _tagsSub?.cancel();
    _memSub?.cancel();
    super.dispose();
  }

  List<MemoryModel> get _visible => _tagId == null
      ? _all
      : _all.where((m) => m.tagIds.contains(_tagId)).toList();

  void _pickTag(String? id) {
    setState(() {
      _tagId = id;
      // Changer de tag redéfinit la sélection : on prend tout le tag.
      _selected
        ..clear()
        ..addAll(_visible.map((m) => m.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final allSelected =
        visible.isNotEmpty && visible.every((m) => _selected.contains(m.id));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Choisir les souvenirs',
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
                _buildTagChips(),
                if (visible.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 12, 0),
                    child: Row(
                      children: [
                        Text(
                          '${_selected.length} souvenir${_selected.length > 1 ? 's' : ''} retenu${_selected.length > 1 ? 's' : ''}',
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textMedium),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setState(() {
                            if (allSelected) {
                              _selected
                                  .removeAll(visible.map((m) => m.id).toSet());
                            } else {
                              _selected.addAll(visible.map((m) => m.id));
                            }
                          }),
                          child: Text(
                            allSelected ? 'Tout décocher' : 'Tout cocher',
                            style: const TextStyle(
                                color: AppColors.sageDark,
                                fontWeight: FontWeight.w600,
                                fontSize: 13),
                          ),
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
                              'Aucun souvenir ici. Choisis un autre tag, ou importe des médias.',
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
                            return _MemoryRow(
                              memory: m,
                              selected: _selected.contains(m.id),
                              onTap: () => setState(() {
                                if (!_selected.remove(m.id)) _selected.add(m.id);
                              }),
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
              disabledBackgroundColor: AppColors.softGray.withOpacity(0.3),
            ),
            child: Text(_selected.isEmpty
                ? 'Sélectionne au moins un souvenir'
                : 'Composer le livre (${_selected.length})'),
          ),
        ),
      ),
    );
  }

  void _continue() {
    final ids = _selected.join(',');
    final tag = _tagId != null ? '&tag=$_tagId' : '';
    context.push('/book/new?memories=$ids$tag');
  }

  Widget _buildTagChips() {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          _Chip(
            label: 'Tous',
            selected: _tagId == null,
            onTap: () => _pickTag(null),
          ),
          ..._tags.map((t) => _Chip(
                label: t.label,
                selected: _tagId == t.id,
                onTap: () => _pickTag(_tagId == t.id ? null : t.id),
              )),
        ],
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
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.sageDark : AppColors.white,
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
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  final MemoryModel memory;
  final bool selected;
  final VoidCallback onTap;
  const _MemoryRow(
      {required this.memory, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = (memory.title?.trim().isNotEmpty ?? false)
        ? memory.title!.trim()
        : (memory.rawContent.trim().isNotEmpty
            ? memory.rawContent.trim()
            : 'Souvenir');
    final date = DateFormat('d MMM yyyy', 'fr').format(memory.date);
    final subtitle = [
      date,
      if ((memory.location ?? '').isNotEmpty) memory.location!,
    ].join(' · ');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.white,
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMedium),
                  ),
                  if (memory.tagLabels.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [
                        for (final l in memory.tagLabels.take(4))
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.sageTint,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(l,
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    color: AppColors.sageDark,
                                    fontWeight: FontWeight.w500)),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
