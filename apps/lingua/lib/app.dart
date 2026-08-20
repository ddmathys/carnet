import 'package:flutter/material.dart';

import 'core/store/store_scope.dart';
import 'core/store/vocab_store.dart';
import 'core/theme.dart';
import 'features/entries/entries_screen.dart';
import 'features/onboarding/language_picker_screen.dart';

class LinguaApp extends StatelessWidget {
  const LinguaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lingua',
      debugShowCheckedModeBanner: false,
      theme: buildLinguaTheme(),
      darkTheme: buildLinguaDarkTheme(),
      home: const _Root(),
    );
  }
}

/// Aiguillage : chargement → choix de la langue → carnet.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final VocabStore store = StoreScope.of(context);

    if (!store.isLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final String? active = store.activeLanguage;
    if (active == null) {
      return const LanguagePickerScreen(isFirstRun: true);
    }

    // La clé force un écran neuf (recherche et filtres remis à zéro) quand on
    // change de langue.
    return EntriesScreen(languageCode: active, key: ValueKey<String>(active));
  }
}
