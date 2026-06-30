import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/generated_book_model.dart';
import '../../core/services/book_history_service.dart';

class BookHistoryScreen extends StatefulWidget {
  final String notebookId;
  const BookHistoryScreen({super.key, required this.notebookId});

  @override
  State<BookHistoryScreen> createState() => _BookHistoryScreenState();
}

class _BookHistoryScreenState extends State<BookHistoryScreen> {
  String? _busyId; // livre en cours de partage

  Future<void> _share(GeneratedBookModel book) async {
    if (_busyId != null) return;
    setState(() => _busyId = book.id);
    try {
      final res = await http
          .get(Uri.parse(book.pdfUrl))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode}';
      }
      await Printing.sharePdf(
        bytes: res.bodyBytes,
        filename: '${book.title.replaceAll(' ', '_')}.pdf',
      );
    } catch (e) {
      if (mounted) _snack('Impossible de récupérer le PDF : $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _confirmDelete(GeneratedBookModel book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Supprimer ce livre ?'),
        content: Text(book.isPrinted
            ? 'L\'entrée et le PDF seront supprimés. La commande d\'impression reste inchangée.'
            : 'Le PDF généré sera définitivement supprimé.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await BookHistoryService.deleteBook(book);
    } catch (e) {
      if (mounted) _snack('Suppression impossible : $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () =>
              context.go('/notebook/${widget.notebookId}/dashboard'),
        ),
        title: const Text(
          'Mes livres',
          style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
      ),
      body: StreamBuilder<List<GeneratedBookModel>>(
        stream: BookHistoryService.streamForNotebook(widget.notebookId),
        builder: (context, snap) {
          if (snap.hasError) return _errorState();
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final books = snap.data!;
          if (books.isEmpty) return _emptyState();
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            itemCount: books.length,
            itemBuilder: (_, i) => _BookTile(
              book: books[i],
              busy: _busyId == books[i].id,
              onShare: () => _share(books[i]),
              onDelete: () => _confirmDelete(books[i]),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/notebook/${widget.notebookId}/book'),
        backgroundColor: AppColors.sage,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Créer un livre'),
        shape: const StadiumBorder(),
      ),
    );
  }

  Widget _errorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                color: AppColors.softGray, size: 40),
            const SizedBox(height: 12),
            const Text(
              'Impossible de charger tes livres.',
              style: TextStyle(color: AppColors.textMedium),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              'Tu peux quand même en créer un nouveau.',
              style: TextStyle(color: AppColors.softGray, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => setState(() {}), // ré-abonne le StreamBuilder
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📚', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 14),
            const Text(
              'Aucun livre généré pour le moment.',
              style: TextStyle(color: AppColors.textMedium, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              'Crée ton premier livre — il apparaîtra ici pour le retrouver, le partager ou le supprimer.',
              style: TextStyle(color: AppColors.softGray, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () =>
                  context.push('/notebook/${widget.notebookId}/book'),
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('Créer mon livre'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  final GeneratedBookModel book;
  final bool busy;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  const _BookTile({
    required this.book,
    required this.busy,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('d MMM yyyy', 'fr').format(book.createdAt);
    return Dismissible(
      key: Key(book.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppColors.error.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline, color: AppColors.error),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false; // la suppression réelle passe par le stream
      },
      child: GestureDetector(
        onTap: busy ? null : onShare,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
          ),
          child: Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: AppColors.sage.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                    child: Text('📖', style: TextStyle(fontSize: 22))),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      style: const TextStyle(
                        fontFamily: 'PlayfairDisplay',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _Chip(
                          label: book.isPrinted ? 'Imprimé' : 'Numérique',
                          color: book.isPrinted
                              ? AppColors.amber
                              : AppColors.sage,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$dateStr · ${book.memoriesCount} souvenir${book.memoriesCount != 1 ? 's' : ''}',
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.textMedium),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              busy
                  ? const SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert,
                          color: AppColors.textMedium),
                      onSelected: (v) {
                        if (v == 'share') onShare();
                        if (v == 'delete') onDelete();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'share',
                          child: Row(children: [
                            Icon(Icons.ios_share,
                                size: 18, color: AppColors.sage),
                            SizedBox(width: 10),
                            Text('Partager'),
                          ]),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(children: [
                            Icon(Icons.delete_outline,
                                size: 18, color: AppColors.error),
                            SizedBox(width: 10),
                            Text('Supprimer'),
                          ]),
                        ),
                      ],
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
