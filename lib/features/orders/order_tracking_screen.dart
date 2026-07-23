import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/order_model.dart';
import '../../core/services/order_service.dart';

class OrdersListScreen extends StatelessWidget {
  const OrdersListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Mes commandes',
          style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () => context.go('/home'),
        ),
      ),
      body: StreamBuilder<List<OrderModel>>(
        stream: OrderService.userOrdersStream(uid),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final orders = snap.data!;
          if (orders.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('📦', style: TextStyle(fontSize: 48)),
                  SizedBox(height: 16),
                  Text('Aucune commande pour l\'instant',
                      style:
                          TextStyle(fontSize: 16, color: AppColors.textMedium)),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(20),
            itemCount: orders.length,
            itemBuilder: (_, i) => _OrderCard(order: orders[i]),
          );
        },
      ),
    );
  }
}

class OrderDetailScreen extends StatelessWidget {
  final String orderId;
  const OrderDetailScreen({super.key, required this.orderId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('Suivi de commande',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          // Cet écran est parfois atteint via context.go() (depuis la
          // confirmation de commande), qui remplace toute la pile de
          // navigation : il n'y a alors rien à "pop" et le bouton ne faisait
          // rien. On retombe sur la liste des commandes dans ce cas.
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/orders'),
        ),
      ),
      body: StreamBuilder<List<OrderModel>>(
        stream: FirebaseAuth.instance.currentUser?.uid != null
            ? OrderService.userOrdersStream(
                FirebaseAuth.instance.currentUser!.uid)
            : const Stream.empty(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final order = snap.data!.where((o) => o.id == orderId).firstOrNull;
          if (order == null) {
            // Commande supprimée/introuvable → message + retour, jamais un
            // spinner infini.
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('✅', style: TextStyle(fontSize: 40)),
                    const SizedBox(height: 12),
                    const Text(
                      'Commande supprimée.',
                      style: TextStyle(color: AppColors.textMedium),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => context.go('/orders'),
                      child: const Text('Mes commandes'),
                    ),
                  ],
                ),
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _OrderTimeline(order: order),
                const SizedBox(height: 24),
                _OrderDetailsCard(order: order),
                const SizedBox(height: 16),
                _PayButton(order: order),
                _PdfDownloadButton(order: order),
                const SizedBox(height: 12),
                _CancelOrderButton(order: order),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final OrderModel order;
  const _OrderCard({required this.order});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/orders/${order.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            Text(order.statusEmoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(order.bookTitle,
                      style: const TextStyle(
                          fontFamily: 'PlayfairDisplay',
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textDark)),
                  const SizedBox(height: 2),
                  Text(order.statusLabel,
                      style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.sage,
                          fontWeight: FontWeight.w600)),
                  Text(DateFormat('d MMM yyyy', 'fr').format(order.createdAt),
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textMedium)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('CHF ${order.price.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark,
                        fontSize: 14)),
                const Icon(Icons.chevron_right,
                    color: AppColors.softGray, size: 18),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderTimeline extends StatelessWidget {
  final OrderModel order;
  const _OrderTimeline({required this.order});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Suivi',
              style: TextStyle(
                  fontFamily: 'PlayfairDisplay',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark)),
          const SizedBox(height: 16),
          ...OrderModel.statusFlow.asMap().entries.map((entry) {
            final i = entry.key;
            final s = entry.value;
            final isDone = order.statusIndex >= i;
            final isCurrent = order.status == s;
            return _TimelineStep(
              emoji: OrderModel(
                id: '',
                userId: '',
                userEmail: '',
                bookTitle: '',
                coverType: '',
                price: 0,
                firstName: '',
                lastName: '',
                street: '',
                city: '',
                npa: '',
                country: '',
                status: s,
                createdAt: DateTime.now(),
                notebookId: '',
                memoryCount: 0,
              ).statusEmoji,
              label: OrderModel(
                id: '',
                userId: '',
                userEmail: '',
                bookTitle: '',
                coverType: '',
                price: 0,
                firstName: '',
                lastName: '',
                street: '',
                city: '',
                npa: '',
                country: '',
                status: s,
                createdAt: DateTime.now(),
                notebookId: '',
                memoryCount: 0,
              ).statusLabel,
              isDone: isDone,
              isCurrent: isCurrent,
              isLast: i == OrderModel.statusFlow.length - 1,
            );
          }),
        ],
      ),
    );
  }
}

class _TimelineStep extends StatelessWidget {
  final String emoji;
  final String label;
  final bool isDone;
  final bool isCurrent;
  final bool isLast;
  const _TimelineStep(
      {required this.emoji,
      required this.label,
      required this.isDone,
      required this.isCurrent,
      required this.isLast});

  @override
  Widget build(BuildContext context) {
    final color = isDone ? AppColors.sage : AppColors.softGray;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: isDone
                    ? AppColors.sage.withOpacity(0.1)
                    : AppColors.background,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: isCurrent ? 2 : 1),
              ),
              child: Center(
                  child: Text(emoji, style: const TextStyle(fontSize: 14))),
            ),
            if (!isLast)
              Container(
                  width: 2,
                  height: 28,
                  color: isDone
                      ? AppColors.sage.withOpacity(0.3)
                      : AppColors.border),
          ],
        ),
        const SizedBox(width: 12),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.normal,
                color: isDone ? AppColors.textDark : AppColors.softGray,
              )),
        ),
      ],
    );
  }
}

class _OrderDetailsCard extends StatelessWidget {
  final OrderModel order;
  const _OrderDetailsCard({required this.order});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Détails',
              style: TextStyle(
                  fontFamily: 'PlayfairDisplay',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark)),
          const SizedBox(height: 12),
          _Row('Livre', order.bookTitle),
          _Row('Couverture', order.coverType == 'hard' ? 'Rigide' : 'Souple'),
          _Row('Livraison', order.fullAddress),
          _Row('Montant', 'CHF ${order.price.toStringAsFixed(2)}'),
          _Row('Commande', '#${order.id.substring(0, 8).toUpperCase()}'),
          _Row('Date', DateFormat('d MMMM yyyy', 'fr').format(order.createdAt)),
          if (order.adminNote != null && order.adminNote!.isNotEmpty) ...[
            const Divider(height: 24, color: AppColors.border),
            Text(order.adminNote!,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMedium,
                    fontStyle: FontStyle.italic)),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 90,
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textMedium))),
            Expanded(
                child: Text(value,
                    style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textDark,
                        fontWeight: FontWeight.w500))),
          ],
        ),
      );
}

class _PayButton extends StatefulWidget {
  final OrderModel order;
  const _PayButton({required this.order});

  @override
  State<_PayButton> createState() => _PayButtonState();
}

class _PayButtonState extends State<_PayButton> {
  bool _loading = false;

  Future<void> _pay() async {
    setState(() => _loading = true);
    try {
      final url = await OrderService.createCheckout(widget.order.id);
      if (!mounted) return;
      if (url == null) {
        _snack('Paiement indisponible pour le moment.');
        return;
      }
      final ok =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok && mounted) _snack('Impossible d\'ouvrir le paiement.');
    } catch (e) {
      if (mounted) _snack('Erreur : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    if (widget.order.status == 'paid') {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.sage.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.sage.withOpacity(0.4)),
        ),
        child: const Row(children: [
          Icon(Icons.check_circle, color: AppColors.sage, size: 18),
          SizedBox(width: 10),
          Text('Payé · merci !',
              style: TextStyle(
                  color: AppColors.sage, fontWeight: FontWeight.w600)),
        ]),
      );
    }
    // Paiement en ligne désactivé (MVP) → on n'affiche pas de bouton « Payer »
    // mais une note : règlement par TWINT après réception, détails par e-mail.
    if (!AppConfig.paymentEnabled) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.amber.withOpacity(0.4)),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🧾', style: TextStyle(fontSize: 18)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Le paiement déclenche la commande de ton livre. L\'équipe '
                'Carnet te contactera rapidement pour les instructions de paiement.',
                style: TextStyle(
                    fontSize: 13, color: AppColors.textDark, height: 1.5),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _loading ? null : _pay,
          icon: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.account_balance_wallet_outlined),
          label: const Text('Payer avec TWINT'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.amber,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }
}

class _PdfDownloadButton extends StatefulWidget {
  final OrderModel order;
  const _PdfDownloadButton({required this.order});

  @override
  State<_PdfDownloadButton> createState() => _PdfDownloadButtonState();
}

class _PdfDownloadButtonState extends State<_PdfDownloadButton> {
  bool _loading = false;

  Future<void> _download() async {
    final url = widget.order.pdfUrl;
    if (url == null) return;
    setState(() => _loading = true);
    try {
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        await Printing.sharePdf(
          bytes: response.bodyBytes,
          filename: '${widget.order.bookTitle.replaceAll(' ', '_')}.pdf',
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Erreur lors du téléchargement')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pdfReady = widget.order.pdfUrl != null;

    if (!pdfReady) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: const Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.sage)),
          SizedBox(width: 12),
          Text('PDF en cours de génération…',
              style: TextStyle(fontSize: 13, color: AppColors.textMedium)),
        ]),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _loading ? null : _download,
        icon: _loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.picture_as_pdf_outlined),
        label: const Text('Télécharger le PDF'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.sage,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }
}

class _CancelOrderButton extends StatefulWidget {
  final OrderModel order;
  const _CancelOrderButton({required this.order});

  @override
  State<_CancelOrderButton> createState() => _CancelOrderButtonState();
}

class _CancelOrderButtonState extends State<_CancelOrderButton> {
  bool _deleting = false;

  // Annulable uniquement avant l'envoi en impression
  static const _cancellableStatuses = {'received', 'validated'};

  bool get _canCancel => _cancellableStatuses.contains(widget.order.status);

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Annuler la commande ?',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay', fontWeight: FontWeight.bold)),
        content: const Text(
            'Cette action est irréversible. La commande et le PDF associé seront supprimés.',
            style: TextStyle(color: Color(0xFF7a6a5a), height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Garder',
                  style: TextStyle(color: Color(0xFF7a6a5a)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Annuler la commande',
                  style: TextStyle(
                      color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // On capture le routeur AVANT les await : la suppression met à jour le
    // stream, ce qui retire ce widget de l'arbre (donc `mounted` devient false
    // et `context` est invalide). Le routeur, lui, reste valable.
    final router = GoRouter.of(context);
    setState(() => _deleting = true);
    try {
      // PDF (sur R2, ou Firebase pour les commandes d'avant la bascule) puis le
      // document Firestore — une seule vérité, dans OrderService.
      await OrderService.deleteOrder(widget.order);
      router.go('/orders');
    } catch (e) {
      if (mounted) {
        setState(() => _deleting = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canCancel) return const SizedBox.shrink();

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _deleting ? null : _cancel,
        icon: _deleting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.red))
            : const Icon(Icons.cancel_outlined, size: 18, color: Colors.red),
        label: const Text('Annuler la commande'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.red,
          side: const BorderSide(color: Colors.red),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}
