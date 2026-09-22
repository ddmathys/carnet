import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/tag_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/date_mask_field.dart';
import '../retro/retro_data.dart';
import 'person_avatar.dart';
import 'tag_picker_sheet.dart' show categoryOfKind, TagCategory;

/// Rangée horizontale des personnes connues, en haut du dashboard : leur
/// pastille (photo ou initiales), pour en ajouter et leur donner une photo
/// sans passer par la création d'un souvenir. Tap sur « + » pour en ajouter
/// une nouvelle ; tap sur une personne propose de changer sa photo, d'ouvrir
/// directement sa rétrospective, et (tags `enfant` seulement) sa courbe de
/// croissance — c'est la seule entrée vers ces deux écrans, plus de
/// raccourci permanent sur le dashboard (voir home_screen.dart).
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
            if (tag.isChild)
              ListTile(
                leading: const Icon(Icons.show_chart,
                    color: AppColors.sageDark),
                title: const Text('Courbe de croissance'),
                onTap: () => Navigator.pop(ctx, 'growth'),
              ),
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
    } else if (choice == 'growth') {
      context.push('/growth/${tag.id}');
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

  /// La sheet propose d'emblée "Activer les mesures (taille/poids)" (David
  /// 22.09.26 — d'abord formulé "c'est un enfant ?", David a préféré cadrer
  /// sur la fonctionnalité plutôt que sur l'étiquette "enfant"). Techniquement
  /// inchangé : activer le switch demande une date de naissance et crée un
  /// tag 'enfant' (TagService.createChildTag) — c'est cette date qui débloque
  /// la courbe de croissance et le badge toise sur sa pastille, aucun autre
  /// mécanisme n'existe pour ça côté données.
  Future<void> _addPerson() async {
    final result = await showNewPersonSheet(context);
    if (result == null || !mounted) return;
    final tag = result.isChild
        ? await TagService.createChildTag(
            label: result.name,
            birthdate: result.birthdate!,
            gender: result.gender!,
          )
        : await TagService.ensureTag(result.name, kind: 'personne');
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
              onMeasureTap: t.isChild
                  ? () => context.push('/growth/${t.id}?add=1')
                  : null,
            ),
          _AddPastille(onTap: _addPerson),
        ],
      ),
    );
  }
}

typedef NewPersonResult = ({
  String name,
  bool isChild,
  DateTime? birthdate,
  String? gender,
});

/// Sheet "Nouvelle personne", avec le toggle "Activer les mesures
/// (taille/poids)" dès le départ — si activé, demande date de naissance +
/// genre (mêmes champs que _AddChildSheet dans memory_create_screen.dart,
/// dupliqués ici plutôt que partagés : cette sheet-là est privée à cet
/// écran, et factoriser à travers deux fichiers pour ~60 lignes n'apportait
/// rien).
Future<NewPersonResult?> showNewPersonSheet(BuildContext context) {
  return showModalBottomSheet<NewPersonResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _NewPersonSheet(),
  );
}

class _NewPersonSheet extends StatefulWidget {
  const _NewPersonSheet();

  @override
  State<_NewPersonSheet> createState() => _NewPersonSheetState();
}

class _NewPersonSheetState extends State<_NewPersonSheet> {
  final _nameCtrl = TextEditingController();
  bool _isChild = false;
  DateTime? _birthdate;
  String _gender = 'boy';

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  bool get _valid =>
      _nameCtrl.text.trim().isNotEmpty && (!_isChild || _birthdate != null);

  void _submit() {
    if (!_valid) return;
    Navigator.pop(
      context,
      (
        name: _nameCtrl.text.trim(),
        isChild: _isChild,
        birthdate: _isChild ? _birthdate : null,
        gender: _isChild ? _gender : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
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
            controller: _nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Prénom'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.monitor_weight_outlined,
                  size: 18, color: AppColors.sage),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Activer les mesures (taille/poids)',
                  style: TextStyle(color: AppColors.textDark, fontSize: 13),
                ),
              ),
              Switch(
                value: _isChild,
                activeTrackColor: AppColors.sage,
                onChanged: (v) => setState(() {
                  _isChild = v;
                  if (!v) _birthdate = null;
                }),
              ),
            ],
          ),
          if (_isChild) ...[
            const SizedBox(height: 4),
            const Text(
              'La date de naissance sert à calculer l\'âge sur la courbe.',
              style: TextStyle(color: AppColors.textMedium, fontSize: 11.5),
            ),
            const SizedBox(height: 4),
            DateMaskField(
              label: 'Date de naissance',
              firstDate: DateTime(1900),
              lastDate: DateTime.now(),
              onChanged: (d) => setState(() => _birthdate = d),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _GenderChip(
                    label: '👦 Garçon',
                    selected: _gender == 'boy',
                    onTap: () => setState(() => _gender = 'boy'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _GenderChip(
                    label: '👧 Fille',
                    selected: _gender == 'girl',
                    onTap: () => setState(() => _gender = 'girl'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _valid ? _submit : null,
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: const Text('Continuer'),
          ),
        ],
      ),
    );
  }
}

class _GenderChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _GenderChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.sage : AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: selected ? AppColors.sage : AppColors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.textDark,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _PersonPastille extends StatelessWidget {
  final String label;
  final String? photoKey;
  final String colorHex;
  final VoidCallback onTap;
  // Badge « toise » sur la pastille — seulement pour un tag enfant (voir
  // categoryOfKind) : accès direct à l'ajout d'une mesure sans passer par
  // « Ajouter un souvenir », demande de David le 22.09.26. Ouvre
  // GrowthScreen avec `?add=1`, qui existait déjà (branché sur un ancien
  // menu « + » du carnet, disparu depuis la refonte du dashboard) mais
  // n'était plus appelé nulle part.
  final VoidCallback? onMeasureTap;
  const _PersonPastille({
    required this.label,
    required this.photoKey,
    required this.colorHex,
    required this.onTap,
    this.onMeasureTap,
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
              Stack(
                clipBehavior: Clip.none,
                children: [
                  PersonAvatar(
                      label: label,
                      photoKey: photoKey,
                      colorHex: colorHex,
                      size: 60),
                  if (onMeasureTap != null)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: GestureDetector(
                        onTap: onMeasureTap,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: AppColors.sageDark,
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: AppColors.background, width: 2),
                          ),
                          child: const Icon(Icons.straighten,
                              size: 12, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
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
