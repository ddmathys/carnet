import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/config/app_config.dart';
import '../../core/models/order_model.dart';
import '../../core/services/order_service.dart';
import '../../core/theme/app_theme.dart';
import 'order_tracking_screen.dart' show OrderPayButton;

class OrderConfirmationScreen extends StatelessWidget {
  final String orderId;
  const OrderConfirmationScreen({super.key, required this.orderId});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Écran atteint via context.go() (remplace la pile de navigation) : le
      // bouton/geste retour système n'a rien à dépiler et quitterait l'app
      // silencieusement sans ça. On redirige vers l'accueil, comme le bouton
      // "Retour à l'accueil" déjà présent plus bas.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/home');
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(),
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppColors.sage.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Text('✅', style: TextStyle(fontSize: 38)),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Commande effectuée',
                  style: TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                // Paiement en ligne actif : on propose de payer TOUT DE SUITE,
                // au lieu de « l'équipe te contactera pour les instructions de
                // paiement » (texte de l'époque du paiement par facture), qui
                // laissait croire qu'il n'y avait rien à faire et cachait le
                // bouton « Payer » dans le suivi de commande (retour 13.10.26).
                if (AppConfig.paymentEnabled)
                  StreamBuilder<OrderModel?>(
                    stream: OrderService.orderStream(orderId),
                    builder: (context, snap) {
                      final order = snap.data;
                      final paid = order?.isPaid ?? false;
                      return Column(children: [
                        Text(
                          paid
                              ? 'Paiement reçu, merci ! On lance la fabrication.'
                              : 'Dernière étape : le paiement. La fabrication '
                                  'démarre dès qu\'il est réglé.',
                          style: const TextStyle(
                              fontSize: 15,
                              color: AppColors.textMedium,
                              height: 1.6),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        if (order != null) OrderPayButton(order: order),
                      ]);
                    },
                  )
                else ...[
                  const Text(
                    'Le paiement déclenchera la fabrication de ta commande.',
                    style: TextStyle(
                        fontSize: 15, color: AppColors.textMedium, height: 1.6),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.amber.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: AppColors.amber.withOpacity(0.4)),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('🧾', style: TextStyle(fontSize: 18)),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'L\'équipe Carnet te contactera rapidement pour les '
                            'instructions de paiement.',
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textDark,
                                height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                OutlinedButton.icon(
                  onPressed: () => context.go('/orders/$orderId'),
                  icon: const Icon(Icons.track_changes_outlined, size: 18),
                  label: const Text('Suivre ma commande'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.sage,
                    side: const BorderSide(color: AppColors.sage),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => context.go('/home'),
                  child: const Text(
                    'Retour à l\'accueil',
                    style: TextStyle(color: AppColors.textMedium, fontSize: 14),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
