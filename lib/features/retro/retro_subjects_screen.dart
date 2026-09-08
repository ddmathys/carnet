import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/tag_service.dart';
import '../tags/person_avatar.dart';
import '../tags/tag_picker_sheet.dart' show TagCategory;
import 'retro_data.dart';

/// Écran A — Choix du sujet.
///
/// Liste les PERSONNES qui ont au moins un souvenir taggé, avec nombre de
/// souvenirs et plage d'années. Volontairement limité aux personnes
/// (lieux/années/événements ont moins de sens à « raconter » comme un sujet).
/// Tags et souvenirs sont suivis en direct (Firestore) : une personne tout
/// juste créée, ou son premier souvenir tagué, apparaît sans quitter/rouvrir
/// cet écran.
class RetroSubjectsScreen extends StatefulWidget {
  const RetroSubjectsScreen({super.key});

  @override
  State<RetroSubjectsScreen> createState() => _RetroSubjectsScreenState();
}

class _RetroSubjectsScreenState extends State<RetroSubjectsScreen> {
  StreamSubscription? _memSub;
  StreamSubscription? _tagSub;
  List<MemoryModel> _memories = [];
  List<TagModel> _tags = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Flux live sur les deux : une personne tout juste créée (ou son premier
    // souvenir taggé) doit apparaître sans quitter/rouvrir cet écran.
    _tagSub = TagService.streamVisible().listen((tags) {
      if (mounted) setState(() => _tags = tags);
    });
    _memSub = MemoryQueryService.visible().listen((mems) {
      if (mounted) setState(() {
        _memories = mems;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _memSub?.cancel();
    _tagSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Uniquement les personnes : un lieu ou une année n'ont pas la même
    // valeur de récit, et mélanger les types rendait l'écran illisible.
    final subjects = RetroSubject.eligible(_memories, _tags)
        .where((s) => s.category == TagCategory.personne)
        .toList();

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
              : CustomScrollView(
                  slivers: [
                    const SliverPadding(
                      padding: EdgeInsets.fromLTRB(20, 10, 20, 6),
                      sliver: SliverToBoxAdapter(
                        child: Text(
                          'Revisite tout ce que tu as gardé sur chacune des '
                          'personnes de tes souvenirs, raconté dans l\'ordre.',
                          style: TextStyle(
                              fontSize: 14, color: AppColors.textMedium),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 10,
                          childAspectRatio: 0.8,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final s = subjects[i];
                            return _PersonCard(
                              subject: s,
                              onTap: () => context.push(
                                '/retro/view',
                                extra: RetroViewArgs(
                                  subject: s,
                                  memories: _memories,
                                  tags: _tags,
                                ),
                              ),
                            );
                          },
                          childCount: subjects.length,
                        ),
                      ),
                    ),
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
              const Text(
                'Tague une personne sur un souvenir pour lui composer un '
                'récit.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: AppColors.textMedium),
              ),
            ],
          ),
        ),
      );
}

/// Une personne, en pastille : sa photo (ou ses initiales), son prénom, le
/// nombre de souvenirs qui lui sont dédiés.
class _PersonCard extends StatelessWidget {
  final RetroSubject subject;
  final VoidCallback onTap;
  const _PersonCard({required this.subject, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        // `white` est réservé au texte/icônes sur fond coloré (voir
        // AppColors) — une carte doit prendre `surface`, sinon le texte clair
        // (pensé pour un fond sombre) devient illisible dessus.
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border, width: 0.6),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PersonAvatar(
                  label: subject.label,
                  photoKey: subject.photoKey,
                  colorHex: subject.color,
                  size: 64,
                ),
                const SizedBox(height: 10),
                Text(
                  subject.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${subject.count} souvenirs',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textMedium),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
