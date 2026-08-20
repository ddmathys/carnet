import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/vocab_entry.dart';
import '../storage/key_value_store.dart';

/// L'état de l'app : les langues suivies et toutes les entrées du carnet.
///
/// Tout tient en mémoire (un carnet, c'est quelques centaines d'entrées) et
/// est réécrit en JSON dans le stockage local à chaque modification.
class VocabStore extends ChangeNotifier {
  VocabStore(this._storage);

  static const String entriesKey = 'lingua.entries.v1';
  static const String settingsKey = 'lingua.settings.v1';

  final KeyValueStore _storage;
  final Random _random = Random();

  List<VocabEntry> _entries = <VocabEntry>[];
  List<String> _languages = <String>[];
  String? _activeLanguage;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  /// Les codes des langues suivies, dans l'ordre d'ajout.
  List<String> get languages => List<String>.unmodifiable(_languages);

  /// La langue affichée. `null` tant qu'aucune langue n'a été choisie.
  String? get activeLanguage => _activeLanguage;

  /// Toutes les entrées, toutes langues confondues (utile pour les tests et
  /// les compteurs). Les écrans passent plutôt par [entriesFor].
  List<VocabEntry> get allEntries => List<VocabEntry>.unmodifiable(_entries);

  // ---------------------------------------------------------------- lecture

  /// Les entrées d'une langue, filtrées, de la plus récente à la plus ancienne.
  ///
  /// [category] : `null` = tous les thèmes, `''` = uniquement les non classées.
  List<VocabEntry> entriesFor(
    String languageCode, {
    String? category,
    String query = '',
    bool hideLearned = false,
  }) {
    return filterEntries(
      _entries,
      languageCode: languageCode,
      category: category,
      query: query,
      hideLearned: hideLearned,
    );
  }

  /// Filtrage pur, sans état : c'est ce que les tests vérifient.
  static List<VocabEntry> filterEntries(
    List<VocabEntry> source, {
    required String languageCode,
    String? category,
    String query = '',
    bool hideLearned = false,
  }) {
    final List<VocabEntry> result = source
        .where((VocabEntry e) => e.languageCode == languageCode)
        .where((VocabEntry e) => category == null || e.category == category)
        .where((VocabEntry e) => !hideLearned || !e.isLearned)
        .where((VocabEntry e) => e.matches(query))
        .toList();
    result.sort((VocabEntry a, VocabEntry b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// Les thèmes utilisés dans une langue, par ordre alphabétique.
  /// Les entrées non classées n'y figurent pas (l'écran ajoute lui-même une
  /// puce « Non classé » quand il y en a).
  List<String> categoriesFor(String languageCode) {
    final Set<String> categories = _entries
        .where((VocabEntry e) => e.languageCode == languageCode)
        .map((VocabEntry e) => e.category)
        .where((String c) => c.isNotEmpty)
        .toSet();
    final List<String> sorted = categories.toList()
      ..sort((String a, String b) =>
          foldForSearch(a).compareTo(foldForSearch(b)));
    return sorted;
  }

  bool hasUncategorized(String languageCode) => _entries.any(
      (VocabEntry e) => e.languageCode == languageCode && e.category.isEmpty);

  int countFor(String languageCode) =>
      _entries.where((VocabEntry e) => e.languageCode == languageCode).length;

  // ---------------------------------------------------------------- langues

  Future<void> addLanguage(String code) async {
    if (!_languages.contains(code)) _languages = <String>[..._languages, code];
    _activeLanguage = code;
    await _persistSettings();
    notifyListeners();
  }

  Future<void> setActiveLanguage(String code) async {
    if (!_languages.contains(code) || _activeLanguage == code) return;
    _activeLanguage = code;
    await _persistSettings();
    notifyListeners();
  }

  /// Retire une langue **et toutes ses entrées** : la garder sans langue la
  /// rendrait invisible et impossible à supprimer ensuite.
  Future<void> removeLanguage(String code) async {
    _languages = _languages.where((String c) => c != code).toList();
    _entries = _entries.where((VocabEntry e) => e.languageCode != code).toList();
    if (_activeLanguage == code) {
      _activeLanguage = _languages.isEmpty ? null : _languages.first;
    }
    await _persistAll();
    notifyListeners();
  }

  // ---------------------------------------------------------------- entrées

  Future<VocabEntry> addEntry({
    required String languageCode,
    required String term,
    String translation = '',
    String context = '',
    String category = '',
  }) async {
    final VocabEntry entry = VocabEntry(
      id: _newId(),
      languageCode: languageCode,
      term: term.trim(),
      translation: translation.trim(),
      context: context.trim(),
      category: category.trim(),
      createdAt: DateTime.now(),
    );
    _entries = <VocabEntry>[..._entries, entry];
    await _persistEntries();
    notifyListeners();
    return entry;
  }

  Future<void> updateEntry(VocabEntry entry) async {
    final int index = _entries.indexWhere((VocabEntry e) => e.id == entry.id);
    if (index == -1) return;
    final List<VocabEntry> updated = <VocabEntry>[..._entries];
    updated[index] = entry.copyWith(
      term: entry.term.trim(),
      translation: entry.translation.trim(),
      context: entry.context.trim(),
      category: entry.category.trim(),
    );
    _entries = updated;
    await _persistEntries();
    notifyListeners();
  }

  Future<void> deleteEntry(String id) async {
    _entries = _entries.where((VocabEntry e) => e.id != id).toList();
    await _persistEntries();
    notifyListeners();
  }

  /// Remet une entrée supprimée à sa place (annulation depuis le SnackBar).
  Future<void> restoreEntry(VocabEntry entry) async {
    if (_entries.any((VocabEntry e) => e.id == entry.id)) return;
    _entries = <VocabEntry>[..._entries, entry];
    await _persistEntries();
    notifyListeners();
  }

  Future<void> setLearned(String id, bool isLearned) async {
    final int index = _entries.indexWhere((VocabEntry e) => e.id == id);
    if (index == -1) return;
    final List<VocabEntry> updated = <VocabEntry>[..._entries];
    updated[index] = updated[index].copyWith(isLearned: isLearned);
    _entries = updated;
    await _persistEntries();
    notifyListeners();
  }

  /// Renomme un thème partout dans une langue (`''` pour tout déclasser).
  Future<void> renameCategory(
      String languageCode, String from, String to) async {
    final String target = to.trim();
    _entries = _entries
        .map((VocabEntry e) =>
            e.languageCode == languageCode && e.category == from
                ? e.copyWith(category: target)
                : e)
        .toList();
    await _persistEntries();
    notifyListeners();
  }

  // ------------------------------------------------------------ persistance

  Future<void> load() async {
    final String? rawSettings = await _storage.read(settingsKey);
    if (rawSettings != null) {
      final Object? decoded = _tryDecode(rawSettings);
      if (decoded is Map<String, dynamic>) {
        final Object? languages = decoded['languages'];
        if (languages is List) {
          _languages = languages.whereType<String>().toList();
        }
        final Object? active = decoded['active'];
        if (active is String && _languages.contains(active)) {
          _activeLanguage = active;
        }
      }
    }
    if (_activeLanguage == null && _languages.isNotEmpty) {
      _activeLanguage = _languages.first;
    }

    final String? rawEntries = await _storage.read(entriesKey);
    if (rawEntries != null) {
      final Object? decoded = _tryDecode(rawEntries);
      if (decoded is List) {
        _entries = decoded
            .whereType<Map<String, dynamic>>()
            .map(VocabEntry.fromJson)
            .where((VocabEntry e) => e.id.isNotEmpty && e.term.isNotEmpty)
            .toList();
      }
    }

    _isLoaded = true;
    notifyListeners();
  }

  Future<void> _persistAll() async {
    await _persistEntries();
    await _persistSettings();
  }

  Future<void> _persistEntries() => _storage.write(
        entriesKey,
        jsonEncode(_entries.map((VocabEntry e) => e.toJson()).toList()),
      );

  Future<void> _persistSettings() => _storage.write(
        settingsKey,
        jsonEncode(<String, dynamic>{
          'languages': _languages,
          'active': _activeLanguage,
        }),
      );

  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      // Données illisibles : on repart d'un carnet vide plutôt que de bloquer
      // le démarrage. Le contenu sera réécrit à la prochaine modification.
      return null;
    }
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(0xFFFFFF)}';
}
