import 'package:flutter/widgets.dart';

import 'vocab_store.dart';

/// Rend le [VocabStore] accessible partout, et reconstruit les écrans qui en
/// dépendent quand il change. Évite d'ajouter une dépendance de gestion
/// d'état pour un MVP à un seul store.
class StoreScope extends InheritedNotifier<VocabStore> {
  const StoreScope({
    super.key,
    required VocabStore store,
    required super.child,
  }) : super(notifier: store);

  static VocabStore of(BuildContext context) {
    final StoreScope? scope =
        context.dependOnInheritedWidgetOfExactType<StoreScope>();
    assert(scope != null, 'Aucun StoreScope au-dessus de ce widget.');
    return scope!.notifier!;
  }
}
