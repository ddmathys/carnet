import 'package:flutter/material.dart';

import '../../core/models/language.dart';
import '../../core/models/vocab_entry.dart';
import '../../core/store/store_scope.dart';
import '../../core/store/vocab_store.dart';
import '../onboarding/language_picker_screen.dart';
import '../review/review_screen.dart';
import 'entry_form_screen.dart';
import 'entry_tile.dart';

/// Le carnet d'une langue : recherche, filtre par thème, liste des entrées.
class EntriesScreen extends StatefulWidget {
  const EntriesScreen({super.key, required this.languageCode});

  final String languageCode;

  @override
  State<EntriesScreen> createState() => _EntriesScreenState();
}

class _EntriesScreenState extends State<EntriesScreen> {
  final TextEditingController _searchController = TextEditingController();

  String _query = '';

  /// `null` = tous les thèmes, `''` = uniquement les entrées non classées.
  String? _category;

  bool _hideLearned = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VocabStore store = StoreScope.of(context);
    final ThemeData theme = Theme.of(context);
    final Language language = languageByCode(widget.languageCode);

    final List<String> categories = store.categoriesFor(widget.languageCode);
    final bool hasUncategorized = store.hasUncategorized(widget.languageCode);

    // Le thème sélectionné peut avoir disparu (dernière entrée supprimée ou
    // renommée) : on retombe sur « Tout » plutôt que d'afficher une liste
    // vide inexplicable.
    final String? category = _resolveCategory(categories, hasUncategorized);

    final List<VocabEntry> entries = store.entriesFor(
      widget.languageCode,
      category: category,
      query: _query,
      hideLearned: _hideLearned,
    );
    final int total = store.countFor(widget.languageCode);
    final bool isFiltering =
        _query.isNotEmpty || category != null || _hideLearned;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: InkWell(
          onTap: () => _openLanguageSheet(store),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(language.flag, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(language.name, overflow: TextOverflow.ellipsis),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Parcourir en cartes',
            icon: const Icon(Icons.style_outlined),
            onPressed: entries.isEmpty ? null : () => _openReview(entries),
          ),
          PopupMenuButton<String>(
            onSelected: (String value) {
              if (value == 'hideLearned') {
                setState(() => _hideLearned = !_hideLearned);
              } else if (value == 'addLanguage') {
                _openLanguagePicker();
              } else if (value == 'removeLanguage') {
                _confirmRemoveLanguage(store, language, total);
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              CheckedPopupMenuItem<String>(
                value: 'hideLearned',
                checked: _hideLearned,
                child: const Text('Masquer les acquis'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'addLanguage',
                child: Text('Ajouter une langue'),
              ),
              PopupMenuItem<String>(
                value: 'removeLanguage',
                child: Text('Supprimer « ${language.name} »'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openForm,
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: (String value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Rechercher un mot, une phrase, un thème…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Effacer',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          if (categories.isNotEmpty || hasUncategorized)
            _CategoryBar(
              categories: categories,
              hasUncategorized: hasUncategorized,
              selected: category,
              onSelected: (String? value) => setState(() => _category = value),
            ),
          if (isFiltering && total > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                '${entries.length} sur $total',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: entries.isEmpty
                ? _EmptyState(
                    isFiltering: isFiltering,
                    onAdd: _openForm,
                    onClearFilters: () {
                      _searchController.clear();
                      setState(() {
                        _query = '';
                        _category = null;
                        _hideLearned = false;
                      });
                    },
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    itemCount: entries.length,
                    itemBuilder: (BuildContext context, int index) {
                      final VocabEntry entry = entries[index];
                      return EntryTile(
                        entry: entry,
                        onTap: () => _openForm(entry: entry),
                        onToggleLearned: () =>
                            store.setLearned(entry.id, !entry.isLearned),
                        onDelete: () => _deleteEntry(store, entry),
                        onCategoryTap: entry.category.isEmpty
                            ? null
                            : () => setState(() => _category = entry.category),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String? _resolveCategory(List<String> categories, bool hasUncategorized) {
    final String? selected = _category;
    if (selected == null) return null;
    if (selected.isEmpty) return hasUncategorized ? '' : null;
    return categories.contains(selected) ? selected : null;
  }

  // ------------------------------------------------------------------ actions

  Future<void> _openForm({VocabEntry? entry}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => EntryFormScreen(
          languageCode: widget.languageCode,
          entry: entry,
        ),
      ),
    );
  }

  Future<void> _openReview(List<VocabEntry> entries) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ReviewScreen(entries: entries),
      ),
    );
  }

  Future<void> _openLanguagePicker() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const LanguagePickerScreen(),
      ),
    );
  }

  Future<void> _deleteEntry(VocabStore store, VocabEntry entry) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await store.deleteEntry(entry.id);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('« ${entry.term} » supprimé'),
        action: SnackBarAction(
          label: 'Annuler',
          onPressed: () => store.restoreEntry(entry),
        ),
      ),
    );
  }

  Future<void> _openLanguageSheet(VocabStore store) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final String code in store.languages)
                ListTile(
                  leading: Text(
                    languageByCode(code).flag,
                    style: const TextStyle(fontSize: 24),
                  ),
                  title: Text(languageByCode(code).name),
                  subtitle: Text('${store.countFor(code)} entrées'),
                  trailing: code == store.activeLanguage
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    store.setActiveLanguage(code);
                  },
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Ajouter une langue'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openLanguagePicker();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmRemoveLanguage(
    VocabStore store,
    Language language,
    int total,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Supprimer « ${language.name} » ?'),
        content: Text(
          total == 0
              ? 'La langue sera retirée de ton carnet.'
              : 'Les $total entrées de cette langue seront supprimées. '
                  'Cette action est définitive.',
        ),
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
    if (confirmed == true) await store.removeLanguage(language.code);
  }
}

/// Barre de filtres : « Tout », « Non classé », puis les thèmes.
class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.categories,
    required this.hasUncategorized,
    required this.selected,
    required this.onSelected,
  });

  final List<String> categories;
  final bool hasUncategorized;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    // 56 et pas 48 : une puce Material 3 occupe déjà 48 de haut avec sa zone
    // de touche, la barre déborderait.
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: <Widget>[
          _chip(context, label: 'Tout', value: null),
          for (final String category in categories)
            _chip(context, label: category, value: category),
          if (hasUncategorized) _chip(context, label: 'Non classé', value: ''),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required String label, required String? value}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Center(
        child: FilterChip(
          label: Text(label),
          selected: selected == value,
          onSelected: (bool _) => onSelected(value),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.isFiltering,
    required this.onAdd,
    required this.onClearFilters,
  });

  final bool isFiltering;
  final VoidCallback onAdd;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              isFiltering ? Icons.search_off : Icons.menu_book_outlined,
              size: 56,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              isFiltering
                  ? 'Aucune entrée ne correspond'
                  : 'Ton carnet est vide',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              isFiltering
                  ? 'Essaie un autre mot, ou enlève les filtres.'
                  : 'Note le premier mot ou la première phrase que tu ne '
                      'connais pas encore.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (isFiltering)
              TextButton.icon(
                onPressed: onClearFilters,
                icon: const Icon(Icons.filter_alt_off_outlined),
                label: const Text('Enlever les filtres'),
              )
            else
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('Ajouter une entrée'),
              ),
          ],
        ),
      ),
    );
  }
}
