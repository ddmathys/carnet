import 'dart:math' show min;

/// Exécute `task` sur chaque item avec au plus `concurrency` en vol
/// simultanément, résultat dans le même ordre que `items`. Tout lancer d'un
/// coup (Future.wait naïf) sur beaucoup d'items sature le réseau/le backend
/// et fait timeouter une partie des requêtes au hasard. Extrait de
/// BookPdfService pour être réutilisé par PosterPdfService.
Future<List<R>> runBounded<T, R>(
  List<T> items,
  Future<R> Function(T item) task, {
  required int concurrency,
}) async {
  final results = List<R?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      results[i] = await task(items[i]);
    }
  }

  await Future.wait(
      List.generate(min(concurrency, items.length), (_) => worker()));
  return results.cast<R>();
}
