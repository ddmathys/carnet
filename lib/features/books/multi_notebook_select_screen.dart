import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/notebook_model.dart';

class MultiNotebookSelectScreen extends StatefulWidget {
  const MultiNotebookSelectScreen({super.key});

  @override
  State<MultiNotebookSelectScreen> createState() =>
      _MultiNotebookSelectScreenState();
}

class _MultiNotebookSelectScreenState extends State<MultiNotebookSelectScreen> {
  final Set<String> _selected = {};
  List<NotebookModel> _notebooks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final snap = await FirebaseFirestore.instance
        .collection('notebooks')
        .where('userId', isEqualTo: uid)
        .get();
    final notebooks = snap.docs
        .map((d) => NotebookModel.fromFirestore(d))
        .toList()
      ..sort((a, b) => (b.lastMemoryAt ?? b.createdAt)
          .compareTo(a.lastMemoryAt ?? a.createdAt));
    if (mounted) {
      setState(() {
        _notebooks = notebooks;
        // Pre-select all by default
        _selected.addAll(notebooks.map((n) => n.id));
        _loading = false;
      });
    }
  }

  Color _cover(NotebookModel n) {
    try {
      return Color(int.parse('FF${n.coverColor.replaceAll('#', '')}', radix: 16));
    } catch (_) {
      return AppColors.sage;
    }
  }

  int get _totalMemories => _notebooks
      .where((n) => _selected.contains(n.id))
      .fold<int>(0, (s, n) => s + n.memoriesCount);

  void _proceed() {
    if (_selected.isEmpty) return;
    final ids = _selected.join(',');
    context.push('/book/new?notebooks=$ids');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          // ── Hero header ──────────────────────────────────────────────────
          Stack(
            children: [
              Container(
                height: 170,
                decoration: const BoxDecoration(gradient: AppColors.heroGradient),
              ),
              Positioned(
                top: -50, right: -50,
                child: Container(
                  width: 180, height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.07), width: 1.5),
                  ),
                ),
              ),
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => context.pop(),
                        padding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Créer un livre',
                        style: TextStyle(
                          fontFamily: 'PlayfairDisplay',
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Sélectionne les carnets à inclure dans le livre.',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.72),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // ── Select all / deselect all ────────────────────────────────────
          if (!_loading && _notebooks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_selected.length}/${_notebooks.length} carnets · $_totalMemories souvenirs',
                    style: const TextStyle(
                        color: AppColors.textMedium,
                        fontSize: 13,
                        fontWeight: FontWeight.w500),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero, minimumSize: Size.zero),
                    onPressed: () => setState(() {
                      if (_selected.length == _notebooks.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(_notebooks.map((n) => n.id));
                      }
                    }),
                    child: Text(
                      _selected.length == _notebooks.length
                          ? 'Tout décocher'
                          : 'Tout cocher',
                      style: const TextStyle(
                          color: AppColors.sage, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),

          // ── List ─────────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _notebooks.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('📔',
                                style: TextStyle(fontSize: 48)),
                            const SizedBox(height: 16),
                            const Text(
                              'Aucun carnet pour l\'instant',
                              style: TextStyle(
                                  fontFamily: 'PlayfairDisplay',
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textDark),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Crée d\'abord un carnet pour générer un livre.',
                              style: TextStyle(
                                  color: AppColors.textMedium, fontSize: 13),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton(
                              onPressed: () => context
                                  .push('/notebook/create/template'),
                              child: const Text('Créer un carnet'),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                        itemCount: _notebooks.length,
                        itemBuilder: (_, i) {
                          final nb = _notebooks[i];
                          final sel = _selected.contains(nb.id);
                          final color = _cover(nb);
                          return GestureDetector(
                            onTap: () => setState(() =>
                                sel ? _selected.remove(nb.id) : _selected.add(nb.id)),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(
                                color: sel
                                    ? AppColors.sageDark.withOpacity(0.06)
                                    : AppColors.white,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: sel ? AppColors.sageDark : AppColors.border,
                                  width: sel ? 2 : 0.5,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                child: Row(
                                  children: [
                                    // Checkbox
                                    AnimatedContainer(
                                      duration: const Duration(milliseconds: 150),
                                      width: 24, height: 24,
                                      decoration: BoxDecoration(
                                        color: sel ? AppColors.sageDark : Colors.transparent,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: sel ? AppColors.sageDark : AppColors.border,
                                          width: 1.5,
                                        ),
                                      ),
                                      child: sel
                                          ? const Icon(Icons.check,
                                              size: 14, color: Colors.white)
                                          : null,
                                    ),
                                    const SizedBox(width: 12),
                                    // Color strip
                                    Container(
                                      width: 6, height: 48,
                                      decoration: BoxDecoration(
                                        color: color,
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    // Emoji
                                    Text(nb.emoji,
                                        style: const TextStyle(fontSize: 28)),
                                    const SizedBox(width: 12),
                                    // Info
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            nb.title,
                                            style: const TextStyle(
                                              fontFamily: 'PlayfairDisplay',
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                              color: AppColors.textDark,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${nb.memoriesCount} souvenir${nb.memoriesCount != 1 ? 's' : ''}',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: AppColors.textMedium),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),

          // ── CTA ──────────────────────────────────────────────────────────
          if (!_loading && _notebooks.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, MediaQuery.of(context).padding.bottom + 20),
              child: ElevatedButton.icon(
                onPressed: _selected.isEmpty ? null : _proceed,
                icon: const Icon(Icons.menu_book_outlined),
                label: Text(_selected.isEmpty
                    ? 'Sélectionne au moins un carnet'
                    : 'Créer le livre · ${_selected.length} carnet${_selected.length > 1 ? 's' : ''}'),
              ),
            ),
        ],
      ),
    );
  }
}
