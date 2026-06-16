import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/order_model.dart';
import '../../core/services/order_service.dart';

const _adminEmail = 'david.mathys24@gmail.com';

class AdminOrdersScreen extends StatefulWidget {
  const AdminOrdersScreen({super.key});

  @override
  State<AdminOrdersScreen> createState() => _AdminOrdersScreenState();
}

class _AdminOrdersScreenState extends State<AdminOrdersScreen> {
  String _filter = 'all'; // 'all' ou un statut

  bool get _isAdmin =>
      FirebaseAuth.instance.currentUser?.email == _adminEmail;

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
    'received'  => 'Reçues',
    'validated' => 'Validées',
    'printing'  => 'Impression',
    'ready'     => 'À envoyer',
    'invoiced'  => 'À payer',
    'paid'      => 'Payées',
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
          color: selected ? AppColors.sage : AppColors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.sage : const Color(0xFFDDD8CC), width: 1),
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
  bool _sendingGelato = false;
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

  Future<void> _sendToGelato() async {
    setState(() => _sendingGelato = true);
    try {
      final res =
          await OrderService.sendToGelato(widget.order.id, orderType: 'draft');
      if (!mounted) return;
      final id = res['gelatoOrderId'];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.sage,
        content: Text(
          'Brouillon créé chez Gelato${id != null ? ' · $id' : ''}. '
          'Valide-le dans le dashboard Gelato pour lancer la production.',
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.error,
        content: Text('Gelato : ${e.toString().replaceFirst('Exception: ', '')}'),
      ));
    } finally {
      if (mounted) setState(() => _sendingGelato = false);
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
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
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
            const Divider(height: 1, color: Color(0xFFDDD8CC)),
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
                            border: Border.all(color: sel ? AppColors.sage : const Color(0xFFDDD8CC)),
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
                  // Bouton PDF pour envoyer à Gelato
                  if (widget.order.pdfUrl != null) SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _downloadingPdf ? null : _downloadPdf,
                      icon: _downloadingPdf
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                      label: const Text('Télécharger PDF → Gelato'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.sage,
                        side: const BorderSide(color: AppColors.sage),
                      ),
                    ),
                  )
                  else
                    _PdfStatusWidget(order: widget.order),

                  // ── Envoi à Gelato (brouillon à valider) ──────────────────
                  if (widget.order.pdfUrl != null) ...[
                    const SizedBox(height: 8),
                    _buildGelatoSection(),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGelatoSection() {
    final o = widget.order;
    if (o.gelatoStatus == 'error' && o.gelatoError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Text('⚠️ Gelato a refusé : ${o.gelatoError}',
                style: const TextStyle(fontSize: 11, color: Colors.red)),
          ),
          const SizedBox(height: 8),
          _gelatoButton(label: 'Réessayer l’envoi à Gelato'),
        ],
      );
    }
    if (o.gelatoOrderId != null) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.sage.withOpacity(0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.sage.withOpacity(0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '✅ Brouillon Gelato créé · ${o.gelatoOrderId}',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sage),
            ),
            const SizedBox(height: 2),
            const Text(
              'Valide-le dans le dashboard Gelato pour lancer la production.',
              style: TextStyle(fontSize: 11, color: AppColors.textMedium),
            ),
          ],
        ),
      );
    }
    return _gelatoButton(label: 'Envoyer à Gelato (brouillon)');
  }

  Widget _gelatoButton({required String label}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _sendingGelato ? null : _sendToGelato,
        icon: _sendingGelato
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
              label: const Text('Télécharger PDF → Gelato'),
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
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('⚠️ Erreur PDF',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.red)),
                const SizedBox(height: 4),
                Text(pdfError,
                  style: const TextStyle(fontSize: 11, color: Colors.red)),
              ],
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFDDD8CC)),
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
