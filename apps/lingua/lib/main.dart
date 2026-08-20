import 'package:flutter/material.dart';

import 'app.dart';
import 'core/storage/key_value_store.dart';
import 'core/store/store_scope.dart';
import 'core/store/vocab_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final VocabStore store = VocabStore(SharedPreferencesStore());
  // Le carnet est petit : on le charge avant le premier écran, ce qui évite
  // un état « vide » qui clignote au démarrage.
  await store.load();

  runApp(StoreScope(store: store, child: const LinguaApp()));
}
