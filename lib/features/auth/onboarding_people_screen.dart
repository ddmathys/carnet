import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/tag_service.dart';
import '../../core/theme/app_theme.dart';
import '../tags/person_avatar.dart';

/// Premier écran après la création d'un compte (jamais après une simple
/// connexion — voir `_postAuthRoute` dans auth_screen.dart, qui ne route ici
/// que si l'utilisateur n'a encore aucune personne). Reprend exactement le
/// geste déjà connu de `PeopleStrip`/`_PersonPickerSheet` (créer une
/// personne, lui donner sa « tête ») mais en plein écran et obligatoire :
/// impossible de continuer sans au moins une personne.
class OnboardingPeopleScreen extends StatefulWidget {
  const OnboardingPeopleScreen({super.key});

  @override
  State<OnboardingPeopleScreen> createState() =>
      _OnboardingPeopleScreenState();
}

class _OnboardingPeopleScreenState extends State<OnboardingPeopleScreen> {
  final List<TagModel> _people = [];
  final _nameCtrl = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _addPerson() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _adding) return;
    setState(() => _adding = true);
    final tag = await TagService.ensureTag(name, kind: 'personne');
    if (!mounted) return;
    setState(() => _adding = false);
    if (tag == null) return;
    _nameCtrl.clear();
    setState(() => _people.add(tag));
    // Enchaîne directement sur la photo — c'est le geste qu'on vient
    // apprendre ici (voir PeopleStrip._addPerson, même logique).
    await _editPhoto(tag);
  }

  Future<void> _editPhoto(TagModel tag) async {
    final updated = await editPersonPhoto(context, tag);
    if (updated == null || !mounted) return;
    setState(() {
      final i = _people.indexWhere((t) => t.id == updated.id);
      if (i != -1) _people[i] = updated;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'D\'abord, qui est avec toi ?',
                style: TextStyle(
                  fontFamily: 'Fraunces',
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ajoute au moins une personne — toi, ton enfant, qui tu '
                'veux. Tu pourras en ajouter d\'autres plus tard.',
                style: TextStyle(fontSize: 14, color: AppColors.textMedium),
              ),
              const SizedBox(height: 28),
              if (_people.isNotEmpty)
                Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    for (final tag in _people)
                      GestureDetector(
                        onTap: () => _editPhoto(tag),
                        child: SizedBox(
                          width: 72,
                          child: Column(
                            children: [
                              PersonAvatar(
                                label: tag.label,
                                photoKey: tag.photoKey,
                                colorHex: tag.color,
                                size: 64,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                tag.label,
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
                  ],
                ),
              if (_people.isNotEmpty) const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameCtrl,
                      autofocus: _people.isEmpty,
                      textCapitalization: TextCapitalization.words,
                      onSubmitted: (_) => _addPerson(),
                      decoration: const InputDecoration(
                        hintText: 'Prénom',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _adding ? null : _addPerson,
                    icon: const Icon(Icons.add_circle,
                        color: AppColors.sageDark, size: 32),
                  ),
                ],
              ),
              const Spacer(),
              SafeArea(
                top: false,
                child: ElevatedButton(
                  onPressed: _people.isEmpty
                      ? null
                      : () => context.go('/home'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child: const Text('Continuer'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
