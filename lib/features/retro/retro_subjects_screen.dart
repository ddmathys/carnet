import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/tag_service.dart';
import '../tags/tag_picker_sheet.dart' show TagCategory, TagCategoryX;
import 'retro_data.dart';

/// Écran A — Choix du sujet.
///
/// Liste les tags qui ont assez de matière pour une rétrospective (≥ 8
/// souvenirs), groupés par type, avec nombre de souvenirs et plage d'années.
/// Tout est calculé côté client à partir des souvenirs déjà en cache.
class RetroSubjectsScreen extends StatefulWidget {
  const RetroSubjectsScreen({super.key});

  @override
  State<RetroSubjectsScreen> createState() => _RetroSubjectsScreenState();
}

class _RetroSubjectsScreenState extends State<RetroSubjectsScreen> {
  StreamSubscription? _memSub;
  List<MemoryModel> _memories = [];
  List<TagModel> _tags = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadTags();
    _memSub = MemoryQueryService.visible().listen((mems) {
      if (mounted) setState(() {
        _memories = mems;
        _loading = false;
      });
    });
  }

  Future<void> _loadTags() async {
    final tags = await TagService.visibleTags();
    if (mounted) setState(() => _tags = tags);
  }

  @override
  void dispose() {
    _memSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subjects = RetroSubject.eligible(_memories, _tags);
    // Groupés par catégorie, dans l'ordre Personne → Lieu → Date → Événement.
    final byCategory = <TagCategory, List<RetroSubject>>{};
    for (final s in subjects) {
      byCategory.putIfAbsent(s.category, () => []).add(s);
    }
    const order = [
      TagCategory.personne,
      TagCategory.lieu,
      TagCategory.date,
      TagCategory.evenement,
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        foregroundColor: AppColors.textDark,
        title: const Text(
          'Rétrospective',
          style: TextStyle(
            fontFamily: 'Fraunces',
            fontWeight: FontWeight.w600,
            color: AppColors.textDark,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : subjects.isEmpty
              ? _empty()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 28),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 4, 4, 16),
                      child: Text(
                        'Revisite tout ce que tu as gardé sur une personne, '
                        'un lieu ou une année, raconté dans l\'ordre.',
                        style: TextStyle(
                            fontSize: 14, color: AppColors.textMedium),
                      ),
                    ),
                    for (final c in order)
                      if ((byCategory[c] ?? const []).isNotEmpty) ...[
                        _CategoryHeader(category: c),
                        for (final s in byCategory[c]!)
                          _SubjectTile(
                            subject: s,
                            onTap: () =>
                                context.push('/retro/view', extra: s),
                          ),
                        const SizedBox(height: 20),
                      ],
                  ],
                ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.auto_stories_outlined,
                  size: 48, color: AppColors.softGray),
              const SizedBox(height: 16),
              const Text(
                'Pas encore de rétrospective',
                style: TextStyle(
                  fontFamily: 'Fraunces',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Il faut au moins ${RetroSubject.minMemories} souvenirs sur '
                'une même personne, un même lieu ou une même année pour '
                'composer un récit.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13.5, color: AppColors.textMedium),
              ),
            ],
          ),
        ),
      );
}

class _CategoryHeader extends StatelessWidget {
  final TagCategory category;
  const _CategoryHeader({required this.category});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Row(
        children: [
          Icon(category.icon, size: 15, color: AppColors.textMedium),
          const SizedBox(width: 6),
          Text(
            category.label.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: AppColors.textMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _SubjectTile extends StatelessWidget {
  final RetroSubject subject;
  final VoidCallback onTap;
  const _SubjectTile({required this.subject, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        subject.label,
                        style: const TextStyle(
                          fontFamily: 'Fraunces',
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${subject.count} souvenirs · ${subject.rangeLabel}',
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textMedium),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.softGray),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
