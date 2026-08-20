import 'package:flutter/material.dart';

import '../../core/models/language.dart';
import '../../core/store/store_scope.dart';
import '../../core/store/vocab_store.dart';

/// Choix de la langue à travailler.
///
/// Sert deux fois : au tout premier lancement ([isFirstRun]), et plus tard
/// depuis le carnet pour ajouter une langue de plus.
class LanguagePickerScreen extends StatelessWidget {
  const LanguagePickerScreen({super.key, this.isFirstRun = false});

  final bool isFirstRun;

  @override
  Widget build(BuildContext context) {
    final VocabStore store = StoreScope.of(context);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(isFirstRun ? 'Bienvenue' : 'Ajouter une langue'),
        automaticallyImplyLeading: !isFirstRun,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Text(
              isFirstRun
                  ? 'Quelle langue veux-tu travailler ?\nTu pourras en ajouter d\'autres plus tard.'
                  : 'Choisis une langue à ajouter à ton carnet.',
              style: theme.textTheme.bodyLarge,
            ),
          ),
          for (final Language language in kLanguages)
            _LanguageTile(
              language: language,
              alreadyAdded: store.languages.contains(language.code),
              count: store.countFor(language.code),
              onTap: () async {
                await store.addLanguage(language.code);
                if (!context.mounted) return;
                // Au premier lancement, l'écran racine bascule tout seul sur
                // le carnet : il n'y a rien à dépiler.
                if (!isFirstRun) Navigator.of(context).pop();
              },
            ),
        ],
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.language,
    required this.alreadyAdded,
    required this.count,
    required this.onTap,
  });

  final Language language;
  final bool alreadyAdded;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Text(language.flag, style: const TextStyle(fontSize: 28)),
      title: Text(language.name),
      subtitle: alreadyAdded
          ? Text(count == 0
              ? 'Déjà dans ton carnet'
              : '$count ${count > 1 ? 'entrées' : 'entrée'}')
          : null,
      trailing: alreadyAdded ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}
