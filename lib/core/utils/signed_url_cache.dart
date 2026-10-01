/// Petit cache à péremption pour les URLs signées de R2.
///
/// Les URLs que le backend délivre sont valables une heure. Les caches
/// d'origine, eux, gardaient leur entrée pour toute la durée de vie du
/// processus : une application laissée ouverte plus d'une heure — le cas
/// normal d'un téléphone — continuait de servir des URLs expirées, et les
/// photos s'affichaient en cadres vides jusqu'au redémarrage (audit du
/// 01.10.26).
///
/// La péremption est volontairement plus courte que la validité réelle : une
/// image dont le chargement commence juste avant l'échéance a le temps de
/// finir.
class SignedUrlCache<T> {
  SignedUrlCache({this.ttl = const Duration(minutes: 50)});

  /// Durée de validité d'une entrée. Les URLs R2 vivent 1 h (`presignGet`).
  final Duration ttl;

  final Map<String, _Entry<T>> _entries = {};

  /// Vrai si la clé a une entrée ENCORE VALABLE. Distingue « rien en cache »
  /// de « en cache, et la valeur est nulle » (un souvenir sans mémo vocal, par
  /// exemple, qu'il ne faut pas re-demander au backend à chaque affichage).
  bool has(String key) {
    final e = _entries[key];
    if (e == null) return false;
    if (_expired(e)) {
      _entries.remove(key);
      return false;
    }
    return true;
  }

  /// Valeur en cache, ou null si absente ou périmée. Vérifier [has] d'abord
  /// quand la valeur elle-même peut être nulle.
  T? get(String key) => has(key) ? _entries[key]!.value : null;

  void put(String key, T value) {
    _entries[key] = _Entry(value, DateTime.now());
  }

  void remove(String key) => _entries.remove(key);

  void clear() => _entries.clear();

  bool _expired(_Entry<T> e) => DateTime.now().difference(e.at) >= ttl;
}

class _Entry<T> {
  final T value;
  final DateTime at;
  const _Entry(this.value, this.at);
}
