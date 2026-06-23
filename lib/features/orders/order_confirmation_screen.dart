import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';

class OrderConfirmationScreen extends StatelessWidget {
  final String orderId;
  const OrderConfirmationScreen({super.key, required this.orderId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Container(
                width: 80, height: 80,
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
              const Text(
                'Vous allez recevoir un email de confirmation.\nNous vous contacterons dès que votre livre est prêt.',
                style: TextStyle(fontSize: 15, color: AppColors.textMedium, height: 1.6),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              // Paiement après livraison (MVP) — aucun paiement en ligne ici.
              Container(
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
                        'Vous paierez après réception du livre, par TWINT. '
                        'Les détails de paiement vous seront envoyés par e-mail.',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textDark, height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: () => context.go('/orders/$orderId'),
                icon: const Icon(Icons.track_changes_outlined, size: 18),
                label: const Text('Suivre ma commande'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.sage,
                  side: const BorderSide(color: AppColors.sage),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
    );
  }
}
