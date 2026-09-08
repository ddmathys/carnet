import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/tag_service.dart';
import '../../core/theme/app_theme.dart';
import '../retro/retro_data.dart';
import 'person_avatar.dart';
import 'tag_picker_sheet.dart' show categoryOfKind, TagCategory;

/// Rangée horizontale des personnes connues, en haut du dashboard : leur
/// pastille (photo ou initiales), pour en ajouter et leur donner une photo
/// sans passer par la création d'un souvenir. Tap sur « + » pour en ajouter
/// une nouvelle ; tap sur une personne propose de changer sa photo ou
/// d'ouvrir directement sa rétrospective — c'est la seule entrée vers la
/// rétrospective, il n'y a plus d'écran « choisis un sujet » à part.
class PeopleStrip extends StatefulWidget {
  const PeopleStrip({super.key});

  @override
  State<PeopleStrip> createState() => _PeopleStripState();
}

class _PeopleStripState extends State<PeopleStrip> {
  StreamSubscription? _tagSub;
  StreamSubscription? _memSub;
  List<TagModel> _allTags = [];
  List<TagModel> _people = [];
  List<MemoryModel> _memories = [];

  @override
  void initState() {
    super.initState();
    _tagSub = TagService.streamVisible().listen((tags) {
      if (!mounted) return;
      setState(() {
        _allTags = tags;
        _people = tags
            .where((t) => categoryOfKind(t.kind) == TagCategory.personne)
            .toList()
          ..sort(
              (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      });
    });
    _memSub = MemoryQueryService.visible().listen((mems) {
      if (mounted) setState(() => _memories = mems);
    });
  }

  @override
  void dispose() {
    _tagSub?.cancel();
    _memSub?.cancel();
    super.dispose();
  }

  Future<void> _onTapPerson(TagModel tag) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.softGray,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  PersonAvatar(
                      label: tag.label,
                      photoKey: tag.photoKey,
                      colorHex: tag.color,
                      size: 40),
                  const SizedBox(width: 12),
                  Text(
                    tag.label,
                    style: const TextStyle(
                      fontFamily: 'Fraunces',
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            ListTile(
              leading: const Icon(Icons.auto_stories_outlined,
                  color: AppColors.sageDark),
              title: const Text('Voir la rétrospective'),
              onTap: () => Navigator.pop(ctx, 'retro'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppColors.sageDark),
              title: const Text('Voir les souvenirs'),
              onTap: () => Navigator.pop(ctx, 'memories'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined,
                  color: AppColors.sageDark),
              title: Text(
                  tag.photoKey == null ? 'Ajouter une photo' : 'Changer la photo'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'photo') {
      await editPersonPhoto(context, tag);
    } else if (choice == 'retro') {
      _openRetro(tag);
    } else if (choice == 'memories') {
      context.push('/memories?tag=${tag.id}');
    }
  }

  /// Sujet déjà éligible (≥ 1 souvenir tagué) correspondant à ce tag, ou
  /// message discret s'il n'y a encore rien à raconter — plutôt que
  /// d'ouvrir un écran de rétrospective vide.
  void _openRetro(TagModel tag) {
    final subjects = RetroSubject.eligible(_memories, _allTags);
    RetroSubject? subject;
    for (final s in subjects) {
      if (s.tagId == tag.id) {
        subject = s;
        break;
      }
    }
    if (subject == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Pas encore de souvenir tagué avec ${tag.label}.')),
      );
      return;
    }
    context.push(
      '/retro/view',
      extra: RetroViewArgs(
          subject: subject, memories: _memories, tags: _allTags),
    );
  }

  Future<void> _addPerson() async {
    final name = await _promptNewPersonName(context);
    if (name == null || name.isEmpty || !mounted) return;
    final tag = await TagService.ensureTag(name, kind: 'personne');
    if (tag == null || !mounted) return;
    // Enchaîne directement sur le choix de la photo — c'est le geste qu'on
    // est venu faire ici, pas juste créer un nom.
    await editPersonPhoto(context, tag);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
        children: [
          for (final t in _people)
            _PersonPastille(
              label: t.label,
              photoKey: t.photoKey,
              colorHex: t.color,
              onTap: () => _onTapPerson(t),
            ),
          _AddPastille(onTap: _addPerson),
        ],
      ),
    );
  }
}

Future<String?> _promptNewPersonName(BuildContext context) {
  final ctrl = TextEditingController();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Nouvelle personne',
            style: TextStyle(
              fontFamily: 'Fraunces',
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Prénom'),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: const Text('Continuer'),
          ),
        ],
      ),
    ),
  );
}

class _PersonPastille extends StatelessWidget {
  final String label;
  final String? photoKey;
  final String colorHex;
  final VoidCallback onTap;
  const _PersonPastille({
    required this.label,
    required this.photoKey,
    required this.colorHex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 64,
          child: Column(
            children: [
              PersonAvatar(
                  label: label, photoKey: photoKey, colorHex: colorHex, size: 60),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMedium,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddPastille extends StatelessWidget {
  final VoidCallback onTap;
  const _AddPastille({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: Column(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surface,
                border: Border.all(color: AppColors.border, width: 1.2),
              ),
              child: const Icon(Icons.add, color: AppColors.sageDark, size: 26),
            ),
            const SizedBox(height: 6),
            const Text(
              'Ajouter',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textMedium,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
