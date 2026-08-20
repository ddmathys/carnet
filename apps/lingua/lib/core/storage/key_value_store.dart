import 'package:shared_preferences/shared_preferences.dart';

/// Le minimum dont le carnet a besoin pour être persisté.
///
/// L'intérêt de l'abstraction : les tests utilisent [MemoryKeyValueStore] et
/// tournent sans plugin de plateforme, alors que l'app utilise
/// [SharedPreferencesStore].
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SharedPreferencesStore implements KeyValueStore {
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<String?> read(String key) async => (await _instance).getString(key);

  @override
  Future<void> write(String key, String value) async =>
      (await _instance).setString(key, value);
}

/// Implémentation en mémoire, pour les tests.
class MemoryKeyValueStore implements KeyValueStore {
  MemoryKeyValueStore([Map<String, String>? seed])
      : _values = <String, String>{...?seed};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
