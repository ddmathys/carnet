import 'package:flutter/material.dart';

import '../../core/models/vocab_entry.dart';
import '../../core/store/store_scope.dart';
import '../../core/store/vocab_store.dart';

/// Parcourir le carnet en cartes : le mot d'abord, la réponse au toucher.
///
/// Le paquet est une photo de la liste filtrée au moment où on entre : les
/// modifications faites pendant le tour ne le réordonnent pas sous les doigts.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.entries});

  final List<VocabEntry> entries;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late List<VocabEntry> _deck;
  int _index = 0;
  bool _revealed = false;
  int _learned = 0;

  @override
  void initState() {
    super.initState();
    _deck = List<VocabEntry>.of(widget.entries)..shuffle();
  }

  void _restart() {
    setState(() {
      _deck = List<VocabEntry>.of(widget.entries)..shuffle();
      _index = 0;
      _revealed = false;
      _learned = 0;
    });
  }

  Future<void> _answer(VocabStore store, {required bool learned}) async {
    final VocabEntry entry = _deck[_index];
    if (learned) _learned++;
    await store.setLearned(entry.id, learned);
    if (!mounted) return;
    setState(() {
      _index++;
      _revealed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final VocabStore store = StoreScope.of(context);
    final ThemeData theme = Theme.of(context);
    final bool finished = _index >= _deck.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Parcourir'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Recommencer',
            icon: const Icon(Icons.refresh),
            onPressed: _restart,
          ),
        ],
      ),
      body: finished
          ? _Finished(
              total: _deck.length,
              learned: _learned,
              onRestart: _restart,
              onClose: () => Navigator.of(context).pop(),
            )
          : Column(
              children: <Widget>[
                LinearProgressIndicator(
                  value: _deck.isEmpty ? 0 : _index / _deck.length,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    '${_index + 1} / ${_deck.length}',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                Expanded(
                  child: _Card(
                    entry: _deck[_index],
                    revealed: _revealed,
                    onTap: () => setState(() => _revealed = !_revealed),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: _revealed
                      ? Row(
                          children: <Widget>[
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () =>
                                    _answer(store, learned: false),
                                child: const Text('À revoir'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: () => _answer(store, learned: true),
                                child: const Text('Je le sais'),
                              ),
                            ),
                          ],
                        )
                      : SizedBox(
                          width: double.infinity,
                          child: FilledButton.tonal(
                            onPressed: () => setState(() => _revealed = true),
                            child: const Text('Afficher la réponse'),
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.entry,
    required this.revealed,
    required this.onTap,
  });

  final VocabEntry entry;
  final bool revealed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (entry.category.isNotEmpty) ...<Widget>[
                      Text(
                        entry.category.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      entry.term,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    if (!revealed) ...<Widget>[
                      const SizedBox(height: 24),
                      Text(
                        'Touche la carte pour voir la réponse',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                    if (revealed) ...<Widget>[
                      const SizedBox(height: 20),
                      const Divider(),
                      const SizedBox(height: 20),
                      Text(
                        entry.translation.isEmpty
                            ? '(pas de traduction notée)'
                            : entry.translation,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: entry.translation.isEmpty
                              ? theme.colorScheme.outline
                              : null,
                        ),
                      ),
                      if (entry.context.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 20),
                        Text(
                          '« ${entry.context} »',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Finished extends StatelessWidget {
  const _Finished({
    required this.total,
    required this.learned,
    required this.onRestart,
    required this.onClose,
  });

  final int total;
  final int learned;
  final VoidCallback onRestart;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.task_alt, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Tour terminé', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '$learned sur $total marqués comme acquis.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRestart,
              icon: const Icon(Icons.refresh),
              label: const Text('Refaire un tour'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: onClose,
              child: const Text('Retour au carnet'),
            ),
          ],
        ),
      ),
    );
  }
}
