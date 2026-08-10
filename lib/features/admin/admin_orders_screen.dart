import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/models/order_model.dart';
import '../../core/services/order_service.dart';

class AdminOrdersScreen extends StatefulWidget {
  const AdminOrdersScreen({super.key});

  @override
  State<AdminOrdersScreen> createState() => _AdminOrdersScreenState();
}

class _AdminOrdersScreenState extends State<AdminOrdersScreen> {
  String _filter = 'all'; // 'all' ou un statut

  bool get _isAdmin =>
      FirebaseAuth.instance.currentUser?.email == AppConfig.adminEmail;

  @override
  Widget build(BuildContext context) {
    if (!_isAdmin) {
      return const Scaffold(
        body: Center(child: Text('Accès refusé')),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.sageDark,
        elevation: 0,
        title: const Text('Console admin',
          style: TextStyle(fontFamily: 'PlayfairDisplay', fontWeight: FontWeight.bold, color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.go('/home'),
        ),
      ),
      body: Column(
        children: [
          // Filtre par statut
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                _FilterChip('Toutes', 'all', _filter, (v) => setState(() => _filter = v)),
                ...OrderModel.statusFlow.map((s) => _FilterChip(
                  _statusShort(s), s, _filter, (v) => setState(() => _filter = v))),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<OrderModel>>(
              stream: OrderService.allOrdersStream(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline,
                              color: AppColors.error, size: 40),
                          const SizedBox(height: 12),
                          const Text('Erreur de chargement des commandes',
                              style: TextStyle(
                                  color: AppColors.textDark,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          Text('${snap.error}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.textMedium)),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: () => setState(() {}),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Réessayer'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final all = snap.data!;
                final orders = _filter == 'all'
                    ? all
                    : all.where((o) => o.status == _filter).toList();
                if (orders.isEmpty) {
                  return const Center(
                    child: Text('Aucune commande', style: TextStyle(color: AppColors.textMedium)));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                  itemCount: orders.length,
                  itemBuilder: (_, i) => _AdminOrderCard(order: orders[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _statusShort(String s) => switch (s) {
    'received' => 'Reçues',
    'paid'     => 'Payées',
    'shipped'  => 'Livrées',
    _ => s,
  };
}

class _FilterChip extends StatelessWidget {
  final String label;
  final String value;
  final String current;
  final ValueChanged<String> onTap;
  const _FilterChip(this.label, this.value, this.current, this.onTap);

  @override
  Widget build(BuildContext context) {
    final selected = current == value;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.sage : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.sage : AppColors.border, width: 1),
        ),
        child: Text(label,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.textMedium)),
      ),
    );
  }
}

class _AdminOrderCard extends StatefulWidget {
  final OrderModel order;
  const _AdminOrderCard({required this.order});

  @override
  State<_AdminOrderCard> createState() => _AdminOrderCardState();
}

class _AdminOrderCardState extends State<_AdminOrderCard> {
  bool _expanded = false;
  bool _saving = false;
  bool _downloadingPdf = false;
  bool _sendingToPrint = false;
  bool _checkingStatus = false;
  bool _checkingQuote = false;
  bool _deleting = false;
  late String _selectedStatus;
  late final TextEditingController _noteCtrl;

  @override
  void initState() {
    super.initState();
    _selectedStatus = widget.order.status;
    _noteCtrl = TextEditingController(text: widget.order.adminNote ?? '');
  }

  Future<void> _downloadPdf() async {
    final url = widget.order.pdfUrl;
    if (url == null || url.isEmpty) return;
    setState(() => _downloadingPdf = true);
    try {
      final response = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        await Printing.sharePdf(
          bytes: response.bodyBytes,
          filename: '${widget.order.bookTitle.replaceAll(' ', '_')}.pdf',
        );
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _downloadingPdf = false);
    }
  }

  // Envoie la commande à l'impression chez Prodigi. Le backend refuse si
  // `order.status != 'paid'` (garde-fou anti-commande gratuite) — le bouton
  // est déjà désactivé côté UI dans ce cas, ceci est la double vérification.
  Future<void> _sendToPrint() async {
    setState(() => _sendingToPrint = true);
    try {
      final res = await OrderService.sendToPrint(widget.order.id);
      if (!mounted) return;
      final id = res['prodigiOrderId'];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.sage,
        content: Text(
          'Commande envoyée à l\'impression${id != null ? ' · $id' : ''}.',
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.error,
        content: Text(e.toString().replaceFirst('Exception: ', '')),
      ));
    } finally {
      if (mounted) setState(() => _sendingToPrint = false);
    }
  }

  // Rafraîchit le vrai statut Prodigi sans attendre le cron quotidien.
  Future<void> _checkStatus() async {
    setState(() => _checkingStatus = true);
    try {
      final res = await OrderService.checkPrintStatus(widget.order.id);
      if (!mounted) return;
      final status = res['prodigiStatus'];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.sage,
        content: Text('Statut impression : ${status ?? 'inconnu'}'),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.error,
        content:
            Text('Vérification : ${e.toString().replaceFirst('Exception: ', '')}'),
      ));
    } finally {
      if (mounted) setState(() => _checkingStatus = false);
    }
  }

  // Vérifie notre prix/pages contre un vrai devis Prodigi (gratuit, ne
  // modifie rien) — à faire avant l'envoi réel, surtout sur une première
  // commande jamais testée en conditions live.
  Future<void> _checkQuote() async {
    final o = widget.order;
    final pageCount = o.pageCount;
    if (pageCount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        backgroundColor: AppColors.error,
        content: Text('Pas de pageCount sur cette commande — regénère le PDF.'),
      ));
      return;
    }
    setState(() => _checkingQuote = true);
    try {
      final res = await OrderService.verifyPrintQuote(
        coverType: o.coverType,
        pageCount: pageCount,
        country: o.country,
      );
      if (!mounted) return;
      final localPages = res['localPrintedPages'];
      final localChf = (res['localPriceChf'] as num?)?.toStringAsFixed(2);
      final prodigiUsd = (res['prodigiCostUsd'] as num?)?.toStringAsFixed(2);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Devis Prodigi (réel)'),
          content: Text(
            'Notre calcul : $localPages pages · CHF $localChf\n'
            'Coût Prodigi (devis live) : ${prodigiUsd != null ? '\$$prodigiUsd' : 'non lisible dans la réponse'}\n\n'
            '${prodigiUsd == null ? 'Le format de réponse Prodigi n\'a pas pu être lu automatiquement — regarde les logs Vercel pour le JSON brut si besoin.' : 'Compare ce coût USD à nos constantes dans book_pricing.dart pour voir si la marge est toujours correcte.'}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.error,
        content: Text(e.toString().replaceFirst('Exception: ', '')),
      ));
    } finally {
      if (mounted) setState(() => _checkingQuote = false);
    }
  }

  Future<void> _deleteOrder() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Supprimer la commande ?'),
        content: const Text(
            'La commande et son PDF seront définitivement supprimés de '
            'l\'application. (Pense à la supprimer aussi chez l\'imprimeur si besoin.)'),
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
    setState(() => _deleting = true);
    try {
      await OrderService.deleteOrder(widget.order);
      // Le stream retire la carte automatiquement.
    } catch (e) {
      if (mounted) {
        setState(() => _deleting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: AppColors.error,
          content: Text('Suppression impossible : $e'),
        ));
      }
    }
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await OrderService.updateStatus(
      widget.order.id,
      _selectedStatus,
      adminNote: _noteCtrl.text.trim().isNotEmpty ? _noteCtrl.text.trim() : null,
    );
    if (mounted) setState(() { _saving = false; _expanded = false; });
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        children: [
          // Header
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Text(o.statusEmoji, style: const TextStyle(fontSize: 22)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(o.bookTitle,
                          style: const TextStyle(fontFamily: 'PlayfairDisplay', fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textDark)),
                        Text('${o.fullName} · ${o.userEmail}',
                          style: const TextStyle(fontSize: 12, color: AppColors.textMedium)),
                        Text('${o.statusLabel} · ${DateFormat('d MMM', 'fr').format(o.createdAt)}',
                          style: const TextStyle(fontSize: 12, color: AppColors.sage, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('CHF ${o.price.toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textDark)),
                      Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                        color: AppColors.softGray, size: 20),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Détail + actions
          if (_expanded) ...[
            const Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Adresse
                  Text('📍 ${o.fullAddress}',
                    style: const TextStyle(fontSize: 13, color: AppColors.textMedium)),
                  Text('${o.coverType == 'hard' ? 'Couverture rigide' : 'Couverture souple'} · ${o.memoryCount} souvenirs',
                    style: const TextStyle(fontSize: 13, color: AppColors.textMedium)),
                  const SizedBox(height: 14),

                  // Changer le statut
                  const Text('Statut', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textMedium)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6, runSpacing: 6,
                    children: OrderModel.statusFlow.map((s) {
                      final sel = _selectedStatus == s;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedStatus = s),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: sel ? AppColors.sage : AppColors.background,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: sel ? AppColors.sage : AppColors.border),
                          ),
                          child: Text(
                            OrderModel(id:'',userId:'',userEmail:'',bookTitle:'',coverType:'',price:0,
                              firstName:'',lastName:'',street:'',city:'',npa:'',country:'',
                              status:s,createdAt:DateTime.now(),notebookId:'',memoryCount:0).statusLabel,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                              color: sel ? Colors.white : AppColors.textMedium)),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),

                  // Note admin
                  TextField(
                    controller: _noteCtrl,
                    maxLines: 2,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Note (visible par le client)',
                      labelStyle: const TextStyle(fontSize: 13, color: AppColors.textMedium),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 12),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Enregistrer'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Bouton PDF (téléchargement manuel, ex. pour vérification)
                  if (widget.order.pdfUrl != null) SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _downloadingPdf ? null : _downloadPdf,
                      icon: _downloadingPdf
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                      label: const Text('Télécharger le PDF'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.sage,
                        side: const BorderSide(color: AppColors.sage),
                      ),
                    ),
                  )
                  else
                    _PdfStatusWidget(order: widget.order),

                  // ── Envoi à l'impression ──────────────────────────────────
                  if (widget.order.pdfUrl != null) ...[
                    const SizedBox(height: 8),
                    _buildPrintSection(),
                  ],

                  // ── Supprimer la commande ─────────────────────────────────
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: _deleting ? null : _deleteOrder,
                      icon: _deleting
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppColors.error))
                          : const Icon(Icons.delete_outline,
                              size: 18, color: AppColors.error),
                      label: const Text('Supprimer la commande',
                          style: TextStyle(color: AppColors.error)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPrintSection() {
    final o = widget.order;

    final statusBadge = switch (o.prodigiStatus) {
      'pending' => _statusBox(
          color: AppColors.amber,
          text: '⏳ En cours chez l\'imprimeur…',
        ),
      'accepted' => _statusBox(
          color: AppColors.sage,
          text: '✅ Accepté · en production',
        ),
      'error' when o.prodigiError != null => _statusBox(
          color: AppColors.error,
          text: '⚠️ Échec de l\'envoi'
              '${o.prodigiRetryCount > 0 ? ' · ${o.prodigiRetryCount}/3 tentatives' : ''}',
          detail: o.prodigiError,
        ),
      _ => null,
    };

    // Garde-fou anti-commande gratuite : impossible d'envoyer à l'impression
    // tant que la commande n'est pas marquée « payée » (même vérification
    // côté backend — voir backend/api/prodigi/[action].ts).
    final canSend = o.status == 'paid';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (statusBadge != null) ...[statusBadge, const SizedBox(height: 8)],
        if (o.prodigiOrderId != null) ...[
          Text('ID Prodigi : ${o.prodigiOrderId}',
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textMedium)),
          const SizedBox(height: 8),
          _checkButton(),
          const SizedBox(height: 8),
        ],
        // Premier envoi : bouton direct, pas de PDF à corriger.
        if (o.prodigiOrderId == null) ...[
          if (o.pageCount != null) ...[
            _quoteButton(),
            const SizedBox(height: 8),
          ],
          _printButton(enabled: canSend, label: 'Envoyer à l\'impression'),
          if (!canSend) ...[
            const SizedBox(height: 6),
            const Text(
              'Marque d\'abord la commande « Payée » pour débloquer l\'envoi.',
              style: TextStyle(fontSize: 11, color: AppColors.textMedium),
            ),
          ],
        ]
        // Erreur : le renvoi passe par l'éditeur (régénère le PDF) plutôt que
        // par un simple retry — plafonné à 3 tentatives (voir OrderModel).
        else if (o.prodigiHasError) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (!canSend || !o.canRetryPrint)
                  ? null
                  : () => context.push(
                      '/book/select?tag=${o.notebookId}&editOrder=${o.id}'),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Modifier le livre et renvoyer'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.amber),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            !canSend
                ? 'Marque d\'abord la commande « Payée » pour débloquer le renvoi.'
                : o.canRetryPrint
                    ? '${o.prodigiRetriesLeft} tentative${o.prodigiRetriesLeft > 1 ? 's' : ''} de renvoi restante${o.prodigiRetriesLeft > 1 ? 's' : ''}.'
                    : 'Nombre maximum de renvois atteint (3) — contacte le support Prodigi si besoin.',
            style: const TextStyle(fontSize: 11, color: AppColors.textMedium),
          ),
        ],
      ],
    );
  }

  Widget _statusBox({required Color color, required String text, String? detail}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(detail,
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textMedium)),
          ],
        ],
      ),
    );
  }

  Widget _quoteButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _checkingQuote ? null : _checkQuote,
        icon: _checkingQuote
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.fact_check_outlined, size: 16),
        label: const Text('Vérifier le devis chez Prodigi'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.amber,
          side: const BorderSide(color: AppColors.amber),
        ),
      ),
    );
  }

  Widget _checkButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _checkingStatus ? null : _checkStatus,
        icon: _checkingStatus
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.refresh, size: 16),
        label: const Text('Vérifier le statut maintenant'),
      ),
    );
  }

  Widget _printButton({required bool enabled, required String label}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: (!enabled || _sendingToPrint) ? null : _sendToPrint,
        icon: _sendingToPrint
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.send_outlined, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(backgroundColor: AppColors.amber),
      ),
    );
  }
}

class _PdfStatusWidget extends StatelessWidget {
  final OrderModel order;
  const _PdfStatusWidget({required this.order});

  @override
  Widget build(BuildContext context) {
    // Lire le champ pdfError depuis Firestore en temps réel
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .doc(order.id)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data() as Map<String, dynamic>?;
        final pdfUrl = data?['pdfUrl'] as String?;
        final pdfError = data?['pdfError'] as String?;

        if (pdfUrl != null) {
          // PDF prêt — afficher le bouton
          return SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                try {
                  final response = await http.get(Uri.parse(pdfUrl))
                      .timeout(const Duration(seconds: 30));
                  if (response.statusCode == 200) {
                    await Printing.sharePdf(
                      bytes: response.bodyBytes,
                      filename: '${order.bookTitle.replaceAll(' ', '_')}.pdf',
                    );
                  }
                } catch (_) {}
              },
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              label: const Text('Télécharger le PDF'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.sage,
                side: const BorderSide(color: AppColors.sage),
              ),
            ),
          );
        }

        if (pdfError != null) {
          return Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.error.withOpacity(0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.error.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('⚠️ Erreur PDF',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.error)),
                const SizedBox(height: 4),
                Text(pdfError,
                  style: const TextStyle(fontSize: 11, color: AppColors.error)),
              ],
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: const Row(children: [
            SizedBox(width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.sage)),
            SizedBox(width: 10),
            Text('PDF en cours de génération…',
              style: TextStyle(fontSize: 12, color: AppColors.textMedium)),
          ]),
        );
      },
    );
  }
}
