import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/tag_service.dart';
import '../shared/upload_status_banner.dart';
import '../tags/share_tag_sheet.dart';
import '../tags/tag_picker_sheet.dart';
import 'widgets/memory_polaroid.dart';
import 'widgets/delete_memory.dart';

/// Tous les souvenirs visibles, filtrables par tag. Remplace le « journal »
/// d'un carnet : il n'y a plus qu'une seule collection de souvenirs, et les
/// tags en sont les rayons.
class MemoriesListScreen extends StatefulWidget {
  /// Tag pré-sélectionné (arrivée depuis une puce de tag du dashboard).
  final String? initialTagId;
  // Arrivée depuis la Chronologie des lieux (année + lieu tapés dans un
  // souvenir) : on coche directement ces deux libellés, pas besoin de
  // résoudre un id de tag (voir _applyInitialTag).
  final String? initialYear;
  final String? initialLocation;

  /// Mode sélection : ouvert pour CHOISIR des souvenirs (ex. composer un
  /// livre) plutôt que pour les consulter. Un tap coche/décoche au lieu
  /// d'ouvrir le souvenir ; une barre "Continuer" en bas renvoie la
  /// sélection via `context.pop(ids)` — l'appelant décide de ce qu'il en
  /// fait (aucune notion de "livre"/"produit" ici, cet écran reste générique).
  final bool selectionMode;
  final String confirmLabel;
  final int minSelection;

  const MemoriesListScreen({
    super.key,
    this.initialTagId,
    this.initialYear,
    this.initialLocation,
    this.selectionMode = false,
    this.confirmLabel = 'Continuer',
    this.minSelection = 1,
  });

  @override
  State<MemoriesListScreen> createState() => _MemoriesListScreenState();
}

class _MemoriesListScreenState extends State<MemoriesListScreen> {
  /// Filtre courant : les libellés de tags cochés (multi-sélection).
  final Set<String> _filterLabels = {};
  final _searchController = TextEditingController();
  String _searchQuery = '';
  // Mode sélection uniquement (widget.selectionMode) : souvenirs cochés.
  final Set<String> _selectedIds = {};
  // Mes tags + ceux qu'on m'a partagés + les tags « fantômes » qui n'existent
  // que sur des souvenirs déjà visibles pour moi (voir
  // TagService.streamFilterable) — avant, cet écran ne listait que
  // `streamMine()` : un collaborateur invité voyait bien les souvenirs
  // partagés dans la grille, mais ne pouvait jamais filtrer dessus ni cocher
  // `initialTagId` à l'arrivée d'un lien de partage (trouvé à l'audit UX du
  // 03.09.26 puis complété à l'audit partage du 15.09.26).
  List<TagModel> _tags = [];
  StreamSubscription? _tagsSub;

  @override
  void initState() {
    super.initState();
    // Année/lieu (Chronologie) : simples libellés, pas besoin d'attendre les
    // tags pour les cocher — contrairement à `initialTagId`, résolu par id.
    if (widget.initialYear != null) _filterLabels.add(widget.initialYear!);
    if (widget.initialLocation != null) {
      _filterLabels.add(widget.initialLocation!);
    }
    _tagsSub = TagService.streamFilterable().listen((tags) {
      if (!mounted) return;
      setState(() {
        _tags = tags;
        _applyInitialTag(tags);
      });
    });
  }

  // Arrivée depuis un tag précis (partage rejoint, CTA livre) : il est coché
  // d'emblée, mais reste modifiable comme n'importe quel filtre. Le tag peut
  // venir de l'un ou l'autre flux (mien ou partagé) — d'où l'appel depuis les
  // deux listeners.
  void _applyInitialTag(List<TagModel> tags) {
    final initial = widget.initialTagId;
    if (initial == null || _filterLabels.isNotEmpty) return;
    for (final t in tags) {
      if (t.id == initial) _filterLabels.add(t.label);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tagsSub?.cancel();
    super.dispose();
  }

  List<TagModel> get _selectedTags =>
      [for (final t in _tags) if (_filterLabels.contains(t.label)) t];

  /// Un seul tag coché → on peut le partager / voir sa croissance depuis l'appbar.
  TagModel? get _soleTag {
    final sel = _selectedTags;
    return sel.length == 1 ? sel.first : null;
  }

  /// Tags cochés qui existent vraiment (pas de fantôme, voir
  /// TagModel.isVirtual) : seuls ceux-là ont un id réel, utilisable pour
  /// partager ou lancer un livre filtré.
  List<TagModel> get _selectedRealTags =>
      _selectedTags.where((t) => !t.isVirtual).toList();

  Future<void> _openFilter() async {
    final result = await showTagPickerSheet(
      context,
      tags: _tags,
      initialLabels: _filterLabels,
    );
    if (result == null || !mounted) return;
    setState(() {
      _filterLabels
        ..clear()
        ..addAll(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tag = _soleTag;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          widget.selectionMode ? 'Choisis tes souvenirs' : (tag?.label ?? 'Mes souvenirs'),
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontWeight: FontWeight.w600,
            color: AppColors.textDark,
          ),
        ),
        leading: IconButton(
          icon: Icon(
            widget.selectionMode ? Icons.close : Icons.arrow_back,
            color: AppColors.textDark,
          ),
          // En mode sélection, on revient à l'écran appelant (choix du
          // format) — jamais au dashboard, qui casserait ce parcours.
          onPressed: () =>
              widget.selectionMode ? context.pop() : context.go('/home'),
        ),
        actions: widget.selectionMode
            ? const []
            : [
          IconButton(
            icon: const Icon(Icons.map_outlined, color: AppColors.textDark),
            tooltip: 'Chronologie des lieux',
            onPressed: () => context.push('/chronology'),
          ),
          // Un tag « enfant » garde sa courbe de croissance — sauf un tag
          // fantôme (voir TagModel.isVirtual) : sa nature est fiable (mirroir
          // `tagKinds`), mais son id ne pointe vers aucun vrai document.
          if (tag != null && tag.isChild && !tag.isVirtual)
            IconButton(
              icon: const Icon(Icons.show_chart, color: AppColors.textDark),
              tooltip: 'Croissance',
              onPressed: () => context.push('/growth/${tag.id}'),
            ),
          // Un ou plusieurs tags cochés → un seul lien les partage tous. Un
          // tag « fantôme » (déduit d'un souvenir déjà partagé, voir
          // TagModel.isVirtual) n'a pas de document réel à partager.
          if (_selectedRealTags.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.ios_share, color: AppColors.textDark),
              tooltip: _selectedRealTags.length == 1
                  ? 'Partager ce tag'
                  : 'Partager ces ${_selectedRealTags.length} tags',
              onPressed: () => showShareTagSheet(context, _selectedRealTags),
            ),
        ],
      ),
      body: Column(
        children: [
          const UploadStatusBanner(),
          Expanded(child: _buildMemoriesStream()),
          if (widget.selectionMode) _buildSelectionBar(),
        ],
      ),
    );
  }

  /// Barre fixe en bas (mode sélection uniquement) : compteur + "Continuer",
  /// désactivé tant que [MemoriesListScreen.minSelection] n'est pas atteint.
  Widget _buildSelectionBar() {
    final count = _selectedIds.length;
    final enabled = count >= widget.minSelection;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
        decoration: const BoxDecoration(
          color: AppColors.background,
          border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                count == 0
                    ? 'Aucun souvenir sélectionné'
                    : '$count souvenir${count > 1 ? 's' : ''} sélectionné${count > 1 ? 's' : ''}',
                style: const TextStyle(
                    fontSize: 13.5, color: AppColors.textMedium, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: enabled ? () => context.pop(_selectedIds.toList()) : null,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 46),
                padding: const EdgeInsets.symmetric(horizontal: 22),
              ),
              child: Text('${widget.confirmLabel}${count > 0 ? ' ($count)' : ''}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemoriesStream() {
    return StreamBuilder<List<MemoryModel>>(
        stream: MemoryQueryService.visible(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          // Les mesures taille/poids ne sont pas des souvenirs comme les
          // autres : elles se saisissent et se consultent uniquement depuis
          // la page croissance (/growth/:tagId), pas ici.
          final all =
              snap.data!.where((m) => m.type != 'taille_poids').toList();
          final selected = _selectedTags;
          final tagFiltered =
              all.where((m) => memoryMatchesTags(m, selected)).toList();
          final filtered = _applySearch(tagFiltered);

          return Column(
            children: [
              _buildSearchBar(),
              if (_tags.isNotEmpty) _buildFilterBar(),
              // CTA "Générer le livre" : uniquement en consultation normale —
              // en mode sélection, la barre du bas ("Continuer") fait déjà ce
              // rôle, un 2ᵉ bouton serait redondant/déroutant.
              if (!widget.selectionMode && tagFiltered.length >= 10)
                _BookCta(
                    count: tagFiltered.length,
                    tagId: _selectedRealTags.length == 1
                        ? _selectedRealTags.first.id
                        : null),
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyState(
                        hasSearch: _searchQuery.trim().isNotEmpty,
                        onClear: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _filterLabels.clear();
                          });
                        },
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 20,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.66,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final m = filtered[i];
                          return MemoryPolaroid(
                            memory: m,
                            cat: _safeCat(m.type),
                            tilt: (i % 2 == 0) ? -0.02 : 0.02,
                            onTap: widget.selectionMode
                                ? () => setState(() {
                                      if (!_selectedIds.remove(m.id)) {
                                        _selectedIds.add(m.id);
                                      }
                                    })
                                : () => context.push('/memory/${m.id}'),
                            onDelete: widget.selectionMode
                                ? null
                                : () => confirmAndDeleteMemory(context, m),
                            selected:
                                widget.selectionMode ? _selectedIds.contains(m.id) : null,
                          );
                        },
                      ),
              ),
            ],
          );
        });
  }

  /// Même filtre que le dashboard : un bouton qui ouvre le sélecteur par
  /// catégories (Date / Lieu / Événement), et le rappel des tags cochés.
  Widget _buildFilterBar() {
    final selected = _filterLabels.toList()..sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _FilterChip(
                label: _filterLabels.isEmpty
                    ? '⚙ Filtrer par tag'
                    : '⚙ ${_filterLabels.length} tag${_filterLabels.length > 1 ? 's' : ''}',
                selected: _filterLabels.isNotEmpty,
                onTap: _openFilter,
              ),
              if (_filterLabels.isNotEmpty)
                TextButton(
                  onPressed: () => setState(_filterLabels.clear),
                  child: const Text('Effacer',
                      style:
                          TextStyle(color: AppColors.textMedium, fontSize: 13)),
                ),
            ],
          ),
          if (selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final label in selected)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.sageTint,
                        borderRadius: BorderRadius.circular(50),
                      ),
                      child: Text(label,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.sageDark,
                              fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _searchQuery = v),
        style: const TextStyle(fontSize: 14, color: AppColors.textDark),
        decoration: InputDecoration(
          hintText: 'Lieu (3 lettres min.) ou date…',
          hintStyle: const TextStyle(fontSize: 13, color: AppColors.softGray),
          prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.softGray),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18, color: AppColors.softGray),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: AppColors.border, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: AppColors.border, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: AppColors.sage, width: 1.5),
          ),
        ),
      ),
    );
  }

  // Strip accents and lowercase — "Genève" → "geneve", "île" → "ile"
  String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[àáâãä]'), 'a')
      .replaceAll(RegExp(r'[èéêë]'), 'e')
      .replaceAll(RegExp(r'[ìíîï]'), 'i')
      .replaceAll(RegExp(r'[òóôõö]'), 'o')
      .replaceAll(RegExp(r'[ùúûü]'), 'u')
      .replaceAll('ç', 'c')
      .replaceAll('ñ', 'n')
      .replaceAll('æ', 'ae')
      .replaceAll('œ', 'oe');

  List<MemoryModel> _applySearch(List<MemoryModel> memories) {
    final q = _norm(_searchQuery.trim());
    if (q.isEmpty) return memories;

    return memories.where((m) {
      if (_matchesDate(m, q)) return true;
      if (q.length >= 3) {
        if (_norm(m.location ?? '').contains(q)) return true;
      }
      return false;
    }).toList();
  }

  bool _matchesDate(MemoryModel m, String normalizedQ) {
    try {
      final d = m.date;
      final checks = [
        DateFormat('dd/MM/yyyy').format(d),
        DateFormat('dd/MM').format(d),
        DateFormat('MM/yyyy').format(d),
        DateFormat('yyyy').format(d),
        _norm(DateFormat('MMMM', 'fr').format(d)),
        _norm(DateFormat('MMMM yyyy', 'fr').format(d)),
      ];
      return checks.any((f) => f.contains(normalizedQ));
    } catch (_) {
      return false;
    }
  }

  MilestoneCategory? _safeCat(String type) {
    try {
      return getMilestoneCategoryById(type);
    } catch (_) {
      return null;
    }
  }

}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.sage : AppColors.surface,
          borderRadius: BorderRadius.circular(50),
          border: Border.all(
            color: selected ? AppColors.sage : AppColors.border,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.white : AppColors.textMedium,
          ),
        ),
      ),
    );
  }
}

class _BookCta extends StatelessWidget {
  final int count;
  final String? tagId;
  const _BookCta({required this.count, this.tagId});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context
          .push('/book/select${tagId != null ? '?tag=$tagId' : ''}'),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.amber.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Text('📖', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$count souvenirs — Générer le livre',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.amber,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.amber, size: 18),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasSearch;
  final VoidCallback onClear;
  const _EmptyState({required this.hasSearch, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🔍', style: TextStyle(fontSize: 36)),
          const SizedBox(height: 12),
          Text(
            hasSearch
                ? 'Aucun souvenir trouvé.'
                : 'Aucun souvenir dans ce filtre.',
            style: const TextStyle(color: AppColors.textMedium),
          ),
          if (hasSearch) ...[
            const SizedBox(height: 4),
            const Text(
              'Essaie un lieu (3 lettres min.) ou une date\nex : Paris · 06/2025 · juin',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.softGray),
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: onClear,
            child: const Text('Effacer la recherche',
                style: TextStyle(color: AppColors.sage)),
          ),
        ],
      ),
    );
  }
}
