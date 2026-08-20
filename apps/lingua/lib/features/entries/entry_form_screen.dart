import 'package:flutter/material.dart';

import '../../core/models/language.dart';
import '../../core/models/vocab_entry.dart';
import '../../core/store/store_scope.dart';
import '../../core/store/vocab_store.dart';

/// Création et modification d'une entrée.
class EntryFormScreen extends StatefulWidget {
  const EntryFormScreen({
    super.key,
    required this.languageCode,
    this.entry,
  });

  final String languageCode;

  /// `null` pour une création.
  final VocabEntry? entry;

  @override
  State<EntryFormScreen> createState() => _EntryFormScreenState();
}

class _EntryFormScreenState extends State<EntryFormScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final FocusNode _termFocus = FocusNode();

  late final TextEditingController _term;
  late final TextEditingController _translation;
  late final TextEditingController _context;
  late final TextEditingController _category;

  bool get _isEditing => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final VocabEntry? entry = widget.entry;
    _term = TextEditingController(text: entry?.term ?? '');
    _translation = TextEditingController(text: entry?.translation ?? '');
    _context = TextEditingController(text: entry?.context ?? '');
    _category = TextEditingController(text: entry?.category ?? '');
  }

  @override
  void dispose() {
    _term.dispose();
    _translation.dispose();
    _context.dispose();
    _category.dispose();
    _termFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VocabStore store = StoreScope.of(context);
    final ThemeData theme = Theme.of(context);
    final Language language = languageByCode(widget.languageCode);
    final List<String> suggestions = store.categoriesFor(widget.languageCode);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Modifier' : 'Nouvelle entrée'),
        actions: <Widget>[
          TextButton(
            onPressed: () => _save(store),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: <Widget>[
            TextFormField(
              controller: _term,
              focusNode: _termFocus,
              autofocus: !_isEditing,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(
                labelText: 'Mot ou phrase (${language.name.toLowerCase()})',
                border: const OutlineInputBorder(),
              ),
              validator: (String? value) =>
                  (value == null || value.trim().isEmpty)
                      ? 'Il faut au moins le mot ou la phrase.'
                      : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _translation,
              decoration: const InputDecoration(
                labelText: 'Traduction',
                helperText: 'Ce que ça veut dire, avec tes mots.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _context,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Contexte',
                helperText: 'La phrase où tu l\'as croisé — c\'est souvent '
                    'elle qui fait retenir le mot.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _category,
              decoration: const InputDecoration(
                labelText: 'Thème',
                helperText: 'Voyage, boulot, cuisine… Laisse vide si tu ne '
                    'sais pas encore.',
                border: OutlineInputBorder(),
              ),
            ),
            if (suggestions.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('Déjà utilisés', style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  for (final String suggestion in suggestions)
                    ActionChip(
                      label: Text(suggestion),
                      onPressed: () {
                        _category.text = suggestion;
                        setState(() {});
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () => _save(store),
              child: const Text('Enregistrer'),
            ),
            if (!_isEditing) ...<Widget>[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _save(store, andNext: true),
                child: const Text('Enregistrer et en ajouter un autre'),
              ),
            ],
            if (_isEditing) ...<Widget>[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _delete(store),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Supprimer cette entrée'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _save(VocabStore store, {bool andNext = false}) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final VocabEntry? existing = widget.entry;

    if (existing == null) {
      await store.addEntry(
        languageCode: widget.languageCode,
        term: _term.text,
        translation: _translation.text,
        context: _context.text,
        category: _category.text,
      );
      if (andNext) {
        // On garde le thème : on note en général plusieurs mots du même
        // contexte à la suite.
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text('« ${_term.text.trim()} » ajouté'),
            duration: const Duration(seconds: 1),
          ),
        );
        _term.clear();
        _translation.clear();
        _context.clear();
        // Pas de Form.reset() ici : avec des contrôleurs externes, il
        // réécrirait le texte qu'on vient d'effacer.
        _termFocus.requestFocus();
        return;
      }
    } else {
      await store.updateEntry(
        existing.copyWith(
          term: _term.text,
          translation: _translation.text,
          context: _context.text,
          category: _category.text,
        ),
      );
    }

    navigator.pop();
  }

  Future<void> _delete(VocabStore store) async {
    final VocabEntry? existing = widget.entry;
    if (existing == null) return;

    final NavigatorState navigator = Navigator.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Supprimer cette entrée ?'),
        content: Text('« ${existing.term} » sera retiré de ton carnet.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await store.deleteEntry(existing.id);
    navigator.pop();
  }
}
