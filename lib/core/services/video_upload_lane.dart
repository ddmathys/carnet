/// Sérialise TOUS les envois vidéo de l'app — la création en cours (upload
/// dès la sélection, voir `DraftMediaUploader`) ET la file d'arrière-plan
/// (`MediaUploadQueue`, sauvegarde/réessai) — sur un seul rail.
///
/// `video_compress` ne gère qu'UNE session de compression native à la fois :
/// compresser deux clips en parallèle fait échouer les deux compressions,
/// même s'ils viennent de deux souvenirs différents. Avant l'upload immédiat
/// à la sélection, un seul appelant (la file d'arrière-plan, déjà
/// séquentielle en interne) existait ; ce rail partagé garde la même garantie
/// maintenant qu'il y en a deux.
class VideoUploadLane {
  VideoUploadLane._();
  static final VideoUploadLane instance = VideoUploadLane._();

  Future<void> _tail = Future<void>.value();

  /// Met [task] en file : il ne démarre qu'une fois tout ce qui le précède
  /// terminé. Un clip en échec ou annulé ne bloque jamais le rail pour
  /// toujours (l'erreur est absorbée ici ; l'appelant reçoit quand même le
  /// résultat/l'erreur de SON propre [task] via le [Future] retourné).
  Future<T> run<T>(Future<T> Function() task) {
    final started = _tail.then((_) => task());
    _tail = started.then((_) {}, onError: (_) {});
    return started;
  }
}
