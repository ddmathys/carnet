import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/tag_service.dart';
import '../../core/theme/app_theme.dart';
import 'person_avatar.dart';
import 'tag_picker_sheet.dart' show categoryOfKind, TagCategory;

/// Rangée horizontale des personnes connues, en haut du dashboard : leur
/// pastille (photo ou initiales), pour en ajouter et leur donner une photo
/// sans passer par la création d'un souvenir. Tap sur une personne pour
/// changer sa photo, tap sur « + » pour en ajouter une nouvelle — la liste
/// se met à jour toute seule (flux Firestore live).
class PeopleStrip extends StatefulWidget {
  const PeopleStrip({super.key});

  @override
  State<PeopleStrip> createState() => _PeopleStripState();
}

class _PeopleStripState extends State<PeopleStrip> {
  StreamSubscription? _sub;
  List<TagModel> _people = [];

  @override
  void initState() {
    super.initState();
    _sub = TagService.streamVisible().listen((tags) {
      if (!mounted) return;
      setState(() {
        _people = tags
            .where((t) => categoryOfKind(t.kind) == TagCategory.personne)
            .toList()
          ..sort(
              (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _editPhoto(TagModel tag) async {
    // Rien à faire du résultat : le flux Firestore live (ci-dessus) rafraîchit
    // la pastille tout seul dès que la photo est enregistrée.
    await editPersonPhoto(context, tag);
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
              onTap: () => _editPhoto(t),
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
