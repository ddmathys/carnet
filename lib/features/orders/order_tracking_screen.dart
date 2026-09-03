import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/generated_book_model.dart';
import '../../core/models/order_model.dart';
import '../../core/services/book_history_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/photo_service.dart';

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
          // Photo de couverture d'une commande LIVRE : pas stockée sur la
          // commande elle-même (contrairement au tirage, voir
          // OrderModel.posterPhotoKey) mais sur l'entrée `generatedBooks`
          // correspondante (`GeneratedBookModel.orderId`) — un 2ᵉ flux, jointe
          // côté client par id de commande.
          return StreamBuilder<List<GeneratedBookModel>>(
            stream: BookHistoryService.streamForUser(),
            builder: (context, bookSnap) {
              final coverByOrderId = <String, GeneratedBookModel>{
                for (final b in bookSnap.data ?? const <GeneratedBookModel>[])
                  if (b.orderId != null && b.orderId!.isNotEmpty)
                    b.orderId!: b,
              };
              return ListView.builder(
                padding: const EdgeInsets.all(20),
                itemCount: orders.length,
                itemBuilder: (_, i) => _OrderCard(
                  order: orders[i],
                  coverBook: coverByOrderId[orders[i].id],
                ),
              );
            },
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
                const SizedBox(height: 16),
                _PrintStatusBanner(order: order),
                const SizedBox(height: 16),
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
  /// Entrée `generatedBooks` correspondante (livre uniquement) — pour la
  /// vignette photo, voir `_OrderThumb`. Null pour un tirage (qui porte sa
  /// propre photo directement sur la commande) ou si rien n'a été retrouvé.
  final GeneratedBookModel? coverBook;
  const _OrderCard({required this.order, this.coverBook});

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
            _OrderThumb(order: order, coverBook: coverBook),
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
                  // Depuis la liste, on veut savoir sans ouvrir la commande si
                  // elle est encore en fabrication ou déjà partie avec un
                  // suivi — le statut seul restait « Payée » pendant des jours.
                  if (order.hasTracking)
                    Text('📮 ${order.primaryShipment!.trackingNumber}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textMedium))
                  else if (order.isPrintInProgress)
                    Text(order.printStageLabel!,
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textMedium)),
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

/// Vignette d'une commande : la photo de couverture (livre) ou "en vedette"
/// (tirage) en plein cadre, comme sur les étagères "Mes livres"/"Mes
/// tirages" du dashboard (même principe que `_CoverThumb`/`_PosterThumb`
/// dans home_screen.dart) — pour reconnaître une commande au premier coup
/// d'œil plutôt qu'au titre/à la date seuls. Repli sur l'emoji de statut
/// (dégradé de la couleur du produit) quand aucune photo n'est disponible :
/// commande sans couverture choisie, ou (livre) aucune entrée
/// `generatedBooks` retrouvée pour les commandes les plus anciennes.
class _OrderThumb extends StatelessWidget {
  final OrderModel order;
  final GeneratedBookModel? coverBook;
  const _OrderThumb({required this.order, this.coverBook});

  @override
  Widget build(BuildContext context) {
    final photoKey =
        order.isPoster ? order.posterPhotoKey : coverBook?.coverPhotoKey;
    final photoUrl =
        order.isPoster ? order.posterPhotoUrl : coverBook?.coverPhotoUrl;

    return Container(
      width: 52,
      height: 52,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      child: _resolve(photoKey, photoUrl),
    );
  }

  Widget _resolve(String? photoKey, String? photoUrl) {
    if (photoKey != null && photoKey.isNotEmpty) {
      return FutureBuilder<Map<String, String>>(
        future: PhotoService.signOwnPhotoKeys([photoKey]),
        builder: (context, snap) {
          final url = snap.data?[photoKey];
          return url != null ? _photo(url) : _fallback();
        },
      );
    }
    if (photoUrl != null && photoUrl.isNotEmpty) return _photo(photoUrl);
    return _fallback();
  }

  Widget _photo(String url) => CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, __) => const ColoredBox(color: Color(0xFF6B4A32)),
        errorWidget: (_, __, ___) => _fallback(),
      );

  Widget _fallback() => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF6B4A32), Color(0xFF8A6242)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Text(order.statusEmoji, style: const TextStyle(fontSize: 22)),
        ),
      );
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
            final isCurrent = order.status == s;
            return _TimelineStep(
              emoji: OrderModel.statusEmojiFor(s),
              label: OrderModel.statusLabelFor(s),
              // Le détail n'apparaît que sur l'étape en cours : sur les
              // autres, il répéterait une évidence ou anticiperait la suite.
              hint: isCurrent ? _stepHint(order, s) : null,
              isDone: order.statusIndex >= i,
              isCurrent: isCurrent,
              isLast: i == OrderModel.statusFlow.length - 1,
            );
          }),
        ],
      ),
    );
  }

  /// Détail affiché sous l'étape en cours. Sur « Payée », on montre l'étape
  /// d'impression réelle plutôt que le texte générique : c'est là que la
  /// commande passe le plus de temps, et c'est précisément là que le client
  /// n'avait aucune idée de ce qu'il se passait.
  String? _stepHint(OrderModel order, String step) {
    if (step == 'paid' && order.printStageLabel != null) {
      return order.printStageLabel;
    }
    if (step == 'shipped' && order.shippedAt != null) {
      return 'Parti le ${DateFormat('d MMMM yyyy', 'fr').format(order.shippedAt!)}';
    }
    return OrderModel.statusHintFor(step);
  }
}

class _TimelineStep extends StatelessWidget {
  final String emoji;
  final String label;
  final String? hint;
  final bool isDone;
  final bool isCurrent;
  final bool isLast;
  const _TimelineStep(
      {required this.emoji,
      required this.label,
      this.hint,
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
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isCurrent ? FontWeight.w700 : FontWeight.normal,
                      color: isDone ? AppColors.textDark : AppColors.softGray,
                    )),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(hint!,
                        style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textMedium,
                            height: 1.35)),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Carte « où en est mon impression » — l'unique endroit où le client voit
/// concrètement ce que fait Prodigi : préparation, fabrication, expédition,
/// avec le numéro de suivi dès qu'un colis est parti.
///
/// Avant, cet écran n'affichait qu'un spinner « Vérification en cours chez
/// l'imprimeur… » identique de l'envoi à la livraison : une commande déjà
/// expédiée depuis deux jours, tracking disponible chez Prodigi, restait
/// visuellement bloquée au même endroit qu'une commande partie la veille.
///
/// Pas de renvoi self-service : contrairement à Gelato, dont le refus
/// n'apparaissait qu'après coup avec un nombre de pages imprévisible,
/// l'admin envoie la commande manuellement une fois payée et corrige/relance
/// depuis la console en cas d'erreur — plus simple, pas de compteur de
/// tentatives à gérer côté client.
class _PrintStatusBanner extends StatefulWidget {
  final OrderModel order;
  const _PrintStatusBanner({required this.order});

  @override
  State<_PrintStatusBanner> createState() => _PrintStatusBannerState();
}

class _PrintStatusBannerState extends State<_PrintStatusBanner> {
  bool _checking = false;
  bool _confirmingReceived = false;

  /// Au-delà de ce délai depuis la dernière relecture, on redemande le statut
  /// à Prodigi dès l'ouverture de l'écran. Le cron backend ne passe qu'une
  /// fois par jour (plan Vercel Hobby) : sans ce rafraîchissement à
  /// l'ouverture, un colis parti le matin ne s'affichait que le lendemain.
  static const _staleAfter = Duration(minutes: 30);

  @override
  void initState() {
    super.initState();
    if (_needsAutoRefresh) {
      // Après le premier frame : `_checkNow` peut appeler setState, et on ne
      // veut pas bloquer le build initial sur un aller-retour réseau.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkNow(silent: true);
      });
    }
  }

  bool get _needsAutoRefresh {
    final o = widget.order;
    if (!o.isPrintInProgress) return false;
    final last = o.prodigiLastCheckedAt;
    return last == null || DateTime.now().difference(last) > _staleAfter;
  }

  /// `silent` : rafraîchissement automatique à l'ouverture — on ne montre pas
  /// d'erreur, l'écran reste utilisable avec les données déjà en base.
  Future<void> _checkNow({bool silent = false}) async {
    setState(() => _checking = true);
    try {
      await OrderService.checkPrintStatus(widget.order.id);
    } catch (e) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Vérification impossible : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _confirmReceived() async {
    setState(() => _confirmingReceived = true);
    try {
      await OrderService.confirmDelivery(widget.order.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : ${e.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    } finally {
      if (mounted) setState(() => _confirmingReceived = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    // 'archived' : le client a déjà confirmé — `printStage` (statut Prodigi
    // brut) reste 'shipped' pour toujours après ça, donc ce cas doit être
    // vérifié EN PREMIER, sinon la carte "En route vers toi" ne disparaît
    // jamais après confirmation.
    if (o.isDelivered) return _delivered();
    switch (o.printStage) {
      case 'error':
        return _blocked(
          'Un souci technique est survenu lors de l\'envoi à l\'imprimeur. '
          'Notre équipe s\'en occupe et te recontacte rapidement.',
        );
      case 'shipped':
        return _shipped(o);
      case 'pending':
      case 'inProduction':
        return _inProgress(o);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _delivered() {
    return _card(
      accent: AppColors.success,
      children: const [
        Row(
          children: [
            Icon(Icons.check_circle, size: 18, color: AppColors.success),
            SizedBox(width: 10),
            Expanded(
              child: Text('Reçue, merci !',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark)),
            ),
          ],
        ),
        SizedBox(height: 10),
      ],
    );
  }

  // ── En cours chez l'imprimeur ──────────────────────────────────────────

  Widget _inProgress(OrderModel o) {
    final isProducing = o.printStage == 'inProduction';
    return _card(
      accent: AppColors.sage,
      children: [
        Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sage,
                  // Libellé lecteur d'écran : sans lui, le spinner est muet.
                  semanticsLabel: o.printStageLabel),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                o.printStageLabel ?? 'Chez l\'imprimeur',
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _PrintSteps(current: o.printStage),
        const SizedBox(height: 10),
        Text(
          isProducing
              ? 'Ton exemplaire est en cours d\'impression. Dès qu\'il part de '
                  'l\'atelier, le numéro de suivi s\'affiche ici.'
              : 'L\'imprimeur prépare le fichier et choisit l\'atelier. '
                  'Comptez 5 à 7 jours ouvrés jusqu\'à l\'expédition.',
          style: const TextStyle(
              fontSize: 12, color: AppColors.textMedium, height: 1.4),
        ),
        _refreshRow(o),
      ],
    );
  }

  // ── Expédiée ───────────────────────────────────────────────────────────

  Widget _shipped(OrderModel o) {
    final parcels = o.dispatchedShipments;
    return _card(
      accent: AppColors.success,
      children: [
        const Row(
          children: [
            Icon(Icons.local_shipping_outlined,
                size: 18, color: AppColors.success),
            SizedBox(width: 10),
            Expanded(
              child: Text('En route vers toi',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _PrintSteps(current: 'shipped'),
        const SizedBox(height: 12),
        if (parcels.isEmpty)
          const Text(
            'Ta commande a quitté l\'atelier. Le numéro de suivi n\'a pas '
            'encore été communiqué par le transporteur.',
            style: TextStyle(
                fontSize: 12, color: AppColors.textMedium, height: 1.4),
          )
        else
          ...parcels.asMap().entries.map((e) => Padding(
                padding: EdgeInsets.only(top: e.key == 0 ? 0 : 10),
                child: _ShipmentTile(
                  shipment: e.value,
                  index: parcels.length > 1 ? e.key + 1 : null,
                  total: parcels.length > 1 ? parcels.length : null,
                ),
              )),
        const SizedBox(height: 10),
        const Text(
          'Le suivi peut mettre quelques heures à s\'activer chez le '
          'transporteur après le départ du colis.',
          style: TextStyle(
              fontSize: 11.5, color: AppColors.textMedium, height: 1.4),
        ),
        _refreshRow(o),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _confirmingReceived ? null : _confirmReceived,
            icon: _confirmingReceived
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('J\'ai bien reçu ma commande'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.success,
              side: const BorderSide(color: AppColors.success),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  // ── Fragments partagés ─────────────────────────────────────────────────

  /// Ligne « dernière vérification + bouton » : rend explicite d'où vient
  /// l'information et à quel point elle est fraîche.
  Widget _refreshRow(OrderModel o) {
    final last = o.prodigiLastCheckedAt;
    return Row(
      children: [
        Expanded(
          child: Text(
            last == null
                ? 'Statut fourni par l\'imprimeur'
                : 'Vérifié le ${DateFormat("d MMM 'à' HH:mm", 'fr').format(last)}',
            style: const TextStyle(fontSize: 11, color: AppColors.softGray),
          ),
        ),
        TextButton(
          onPressed: _checking ? null : () => _checkNow(),
          child: _checking
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, semanticsLabel: 'Vérification en cours'),
                )
              : const Text('Actualiser'),
        ),
      ],
    );
  }

  Widget _card({required Color accent, required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _blocked(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.error.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.error.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.support_agent_outlined, size: 18, color: AppColors.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textDark, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

/// Les trois étapes d'impression, en une ligne compacte — permet de situer
/// « préparation / fabrication / expédié » d'un coup d'œil, là où l'ancien
/// spinner ne distinguait rien.
class _PrintSteps extends StatelessWidget {
  final String? current;
  const _PrintSteps({required this.current});

  static const _steps = [
    ('pending', 'Préparation'),
    ('inProduction', 'Fabrication'),
    ('shipped', 'Expédié'),
  ];

  @override
  Widget build(BuildContext context) {
    final currentIndex = _steps.indexWhere((s) => s.$1 == current);
    // `scaleDown` plutôt qu'un Row nu : les trois libellés tiennent de justesse
    // sur un petit écran, et un débordement afficherait la bande jaune
    // d'overflow au milieu de la carte. `MainAxisSize.min` est obligatoire :
    // FittedBox donne une largeur non bornée à son enfant.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _steps.asMap().entries.expand((e) {
          final done = currentIndex >= e.key;
          final isCurrent = currentIndex == e.key;
          return <Widget>[
            if (e.key > 0)
              Container(
                width: 14,
                height: 1.5,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                color: done ? AppColors.sage : AppColors.border,
              ),
            Text(
              e.value.$2,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
                color: done ? AppColors.textDark : AppColors.softGray,
              ),
            ),
          ];
        }).toList(),
      ),
    );
  }
}

/// Un colis : transporteur, date et pays de départ, numéro de suivi copiable
/// et bouton vers le site du transporteur.
class _ShipmentTile extends StatelessWidget {
  final OrderShipment shipment;
  /// Rang du colis quand la commande en compte plusieurs (sinon null).
  final int? index;
  final int? total;
  const _ShipmentTile({required this.shipment, this.index, this.total});

  Future<void> _copy(BuildContext context) async {
    final number = shipment.trackingNumber;
    if (number == null) return;
    await Clipboard.setData(ClipboardData(text: number));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Numéro de suivi copié')),
    );
  }

  Future<void> _open(BuildContext context) async {
    final url = shipment.trackingUrl;
    if (url == null) return;
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'ouvrir le suivi')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final from = shipment.fromCountryLabel;
    final date = shipment.dispatchedAt;
    final origin = from != null ? ' depuis $from' : '';
    // Prodigi ne remplit pas toujours les trois champs : on compose une phrase
    // correcte avec ce qui existe plutôt que de coller des morceaux.
    final subtitle = [
      if (date != null)
        'Expédié le ${DateFormat('d MMMM', 'fr').format(date)}$origin'
      else if (from != null)
        'Fabriqué$origin',
      if (shipment.carrier != null) '· ${shipment.carrier}',
    ].join(' ');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (index != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('Colis $index sur $total',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textMedium)),
            ),
          if (subtitle.isNotEmpty)
            Text(subtitle,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textMedium, height: 1.4)),
          if (shipment.trackingNumber != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    shipment.trackingNumber!,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  color: AppColors.textMedium,
                  tooltip: 'Copier le numéro de suivi',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (shipment.trackingUrl != null)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _open(context),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Suivre mon colis'),
                ),
              ),
          ],
        ],
      ),
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
                'Carnet te contactera rapidement pour les instructions de '
                'paiement, puis ton livre sera livré sous quelques jours.',
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

  // Annulable uniquement avant paiement
  static const _cancellableStatuses = {'received'};

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
            style: TextStyle(color: AppColors.textMedium, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Garder',
                  style: TextStyle(color: AppColors.textMedium))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Annuler la commande',
                  style: TextStyle(
                      color: AppColors.error, fontWeight: FontWeight.w600))),
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
      await OrderService.cancelOrder(widget.order.id);
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
                    strokeWidth: 2, color: AppColors.error))
            : const Icon(Icons.cancel_outlined, size: 18, color: AppColors.error),
        label: const Text('Annuler la commande'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.error,
          side: const BorderSide(color: AppColors.error),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}
