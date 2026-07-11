import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/quota_service.dart';

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  QuotaStatus? _quota;
  String _tier = 'free';
  bool _requested = false; // l'utilisateur a déjà demandé Premium
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final tier = await QuotaService.getSubscriptionTier(uid);
    final quota = await QuotaService.checkQuota(uid);
    bool requested = false;
    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      requested = doc.data()?['premiumRequested'] == true;
    } catch (_) {}
    if (mounted) {
      setState(() {
        _tier = tier;
        _quota = quota;
        _requested = requested;
      });
    }
  }

  // Le paiement en ligne n'est pas encore actif : on enregistre l'intérêt de
  // l'utilisateur (sur son doc `users`, écriture autorisée par les règles tant
  // qu'on ne touche pas `subscriptionTier`). L'admin recontacte ensuite.
  Future<void> _requestPremium() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _requesting = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'premiumRequested': true,
        'premiumRequestedAt': FieldValue.serverTimestamp(),
        'email': user.email,
      }, SetOptions(merge: true));
      if (mounted) setState(() => _requested = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur, réessaie : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPremium = _tier == 'premium';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Abonnement',
          style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Current status banner
            if (_quota != null) ...[
              _QuotaBanner(quota: _quota!, isPremium: isPremium),
              const SizedBox(height: 24),
            ],

            // Tagline
            const Text(
              'Soutiens Carnet\net débloque le plein potentiel de tes carnets.',
              style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Carnet est développé avec soin par une équipe indépendante. Ton abonnement permet de continuer à améliorer l\'app.',
              style: TextStyle(color: AppColors.textMedium, fontSize: 13, height: 1.5),
            ),

            const SizedBox(height: 28),

            // Comparison table
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _PlanCard(
                  label: 'Gratuit',
                  price: null,
                  isCurrent: !isPremium,
                  features: [
                    _Feature('${QuotaService.freePhotoLimit} photos', true),
                    _Feature('${QuotaService.freeVideoLimit} vidéos '
                        '(${QuotaService.freeVideoDurationSec ~/ 60} min)', true),
                    _Feature('${QuotaService.freeAudioLimit} mémos vocaux', true),
                    const _Feature('Carnets illimités', true),
                    const _Feature('Génération PDF', true),
                    const _Feature('Support prioritaire', false),
                  ],
                )),
                const SizedBox(width: 12),
                Expanded(child: _PlanCard(
                  label: 'Premium',
                  price: 'CHF ${QuotaService.premiumPriceChf.toStringAsFixed(0)} / an',
                  isCurrent: isPremium,
                  featured: true,
                  features: [
                    _Feature('${QuotaService.premiumPhotoLimit} photos', true),
                    _Feature('${QuotaService.premiumVideoLimit} vidéos HD '
                        '(${QuotaService.premiumVideoDurationSec ~/ 60} min)', true),
                    _Feature('${QuotaService.premiumAudioLimit} mémos vocaux', true),
                    const _Feature('Carnets illimités', true),
                    const _Feature('Génération PDF', true),
                    const _Feature('Support prioritaire', true),
                  ],
                )),
              ],
            ),

            const SizedBox(height: 28),

            // Transparency note
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.sage.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.sage.withOpacity(0.2)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, color: AppColors.sage, size: 16),
                      SizedBox(width: 6),
                      Text('Transparence', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.sage)),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    '• Photos & mémos vocaux : Google Firebase (UE)\n'
                    '• Vidéos : Cloudflare R2 (UE), accès privé par liens signés\n'
                    '• Tes données ne sont jamais vendues\n'
                    '• Résiliable à tout moment, sans engagement\n'
                    '• Prix en CHF, facturation annuelle',
                    style: TextStyle(color: AppColors.textMedium, fontSize: 12, height: 1.6),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // CTA — le paiement en ligne n'est pas encore actif : l'utilisateur
            // peut DEMANDER l'accès Premium, on le recontacte.
            if (!isPremium) ...[
              if (_requested) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.sage.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.sage.withOpacity(0.3)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle, color: AppColors.sage, size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Demande enregistrée — on te recontacte dès que le paiement est ouvert. Merci !',
                          style: TextStyle(
                              color: AppColors.sage,
                              fontWeight: FontWeight.w600,
                              fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _requesting ? null : _requestPremium,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.sage,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      textStyle: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    child: _requesting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : Text(
                            'Demander Premium · CHF ${QuotaService.premiumPriceChf.toStringAsFixed(0)} / an'),
                  ),
                ),
                const SizedBox(height: 10),
                const Center(
                  child: Text(
                    'Le paiement en ligne arrive bientôt — réserve ton accès dès maintenant.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMedium, fontSize: 12),
                  ),
                ),
              ],
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.sage.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.sage.withOpacity(0.3)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle, color: AppColors.sage, size: 20),
                    SizedBox(width: 10),
                    Text('Tu es abonné Premium — merci !',
                      style: TextStyle(color: AppColors.sage, fontWeight: FontWeight.w700, fontSize: 15)),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Feature {
  final String label;
  final bool included;
  const _Feature(this.label, this.included);
}

class _PlanCard extends StatelessWidget {
  final String label;
  final String? price;
  final bool isCurrent;
  final bool featured;
  final List<_Feature> features;

  const _PlanCard({
    required this.label,
    required this.price,
    required this.isCurrent,
    this.featured = false,
    required this.features,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = featured ? AppColors.sage : const AppColors.border;
    final bg = featured ? AppColors.sage.withOpacity(0.04) : AppColors.white;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: featured ? 2 : 1),
        boxShadow: featured ? [
          BoxShadow(color: AppColors.sage.withOpacity(0.12), blurRadius: 16, offset: const Offset(0, 4)),
        ] : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (featured)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.sage,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('Recommandé', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
            ),
          if (featured) const SizedBox(height: 8),
          Text(label, style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontSize: 17, fontWeight: FontWeight.bold,
            color: featured ? AppColors.sage : AppColors.textDark,
          )),
          const SizedBox(height: 4),
          price != null
              ? Text(price!, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textDark))
              : const Text('Gratuit', style: TextStyle(fontSize: 13, color: AppColors.textMedium)),
          if (isCurrent) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.sage.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('Plan actuel', style: TextStyle(color: AppColors.sage, fontSize: 10, fontWeight: FontWeight.w600)),
            ),
          ],
          const SizedBox(height: 14),
          const Divider(height: 1, color: Color(0xFFEEEBE3)),
          const SizedBox(height: 12),
          ...features.map((f) => Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  f.included ? Icons.check_circle_outline : Icons.radio_button_unchecked,
                  size: 15,
                  color: f.included ? AppColors.sage : AppColors.softGray,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    f.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: f.included ? AppColors.textDark : AppColors.softGray,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}

class _QuotaBanner extends StatelessWidget {
  final QuotaStatus quota;
  final bool isPremium;
  const _QuotaBanner({required this.quota, required this.isPremium});

  @override
  Widget build(BuildContext context) {
    final color = quota.isAtLimit
        ? AppColors.error
        : quota.nearLimit
            ? AppColors.amber
            : AppColors.sage;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${quota.current} / ${quota.limit} photos',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: color),
              ),
              Text(
                isPremium ? 'Premium' : 'Gratuit',
                style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: quota.ratio,
              minHeight: 6,
              backgroundColor: color.withOpacity(0.15),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          if (!isPremium && quota.nearLimit) ...[
            const SizedBox(height: 8),
            Text(
              quota.isAtLimit
                  ? 'Limite atteinte. Passe à Premium pour continuer à ajouter des photos.'
                  : 'Il te reste ${quota.remaining} photos. Pense à passer à Premium.',
              style: TextStyle(fontSize: 12, color: color, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}
