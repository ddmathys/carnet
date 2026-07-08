import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';

/// Écran d'accueil / onboarding affiché aux utilisateurs non connectés.
/// Met en avant la sécurité et la transparence, puis oriente vers la création
/// de compte ou la connexion.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  // Points de confiance — formulés d'après le fonctionnement réel de l'app
  // (règles Firestore d'ownership, stockage privé + URLs signées, auth Firebase).
  static const _points = <_TrustPoint>[
    _TrustPoint(
      icon: Icons.lock_outline,
      title: 'Privé par défaut',
      desc: 'Chaque carnet n\'est visible que par toi et les proches que tu '
          'invites. Personne d\'autre.',
    ),
    _TrustPoint(
      icon: Icons.shield_outlined,
      title: 'Photos & vidéos protégées',
      desc: 'Stockées de façon privée, accessibles uniquement via des liens '
          'sécurisés et temporaires.',
    ),
    _TrustPoint(
      icon: Icons.verified_user_outlined,
      title: 'Connexion sécurisée',
      desc: 'Via Google ou email, gérée par Firebase. L\'app ne conserve '
          'jamais ton mot de passe.',
    ),
    _TrustPoint(
      icon: Icons.import_export,
      title: 'Tu gardes le contrôle',
      desc: 'Exporte tes souvenirs en livre ou supprime-les définitivement, '
          'quand tu veux.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.sageDark,
      body: Stack(
        children: [
          // Fond dégradé + cercles décoratifs (cohérent avec l'écran d'auth).
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: AppColors.heroGradient),
            ),
          ),
          Positioned(
            top: -100,
            right: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border:
                    Border.all(color: Colors.white.withOpacity(0.07), width: 1.5),
              ),
            ),
          ),
          Positioned(
            top: -40,
            right: -50,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.05),
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Marque
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Center(
                          child: SvgPicture.asset(
                            'assets/images/bloom_logo_v3.svg',
                            width: 23,
                            height: 23,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'carnet',
                        style: TextStyle(
                          fontFamily: 'PlayfairDisplay',
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          fontStyle: FontStyle.italic,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 28),

                  // Titre d'accroche
                  const Text(
                    'Tes souvenirs,\nen sécurité.',
                    style: TextStyle(
                      fontFamily: 'PlayfairDisplay',
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      height: 1.12,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Un carnet intime pour capturer les moments qui comptent — '
                    'pensé pour la confidentialité et la transparence.',
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: Colors.white.withOpacity(0.78),
                    ),
                  ),

                  const SizedBox(height: 22),

                  // Carte des points de confiance
                  Expanded(
                    child: SingleChildScrollView(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.12)),
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < _points.length; i++) ...[
                              _TrustRow(point: _points[i]),
                              if (i != _points.length - 1)
                                Divider(
                                  height: 1,
                                  color: Colors.white.withOpacity(0.08),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),

                  // CTA principal — création de compte
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => context.push('/auth?mode=signup'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.cream,
                        foregroundColor: AppColors.sageDark,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        textStyle: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16),
                      ),
                      child: const Text('Créer un compte'),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // CTA secondaire — connexion
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => context.push('/auth?mode=login'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        side: BorderSide(color: Colors.white.withOpacity(0.4)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        textStyle: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      child: const Text('J\'ai déjà un compte'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrustPoint {
  final IconData icon;
  final String title;
  final String desc;
  const _TrustPoint(
      {required this.icon, required this.title, required this.desc});
}

class _TrustRow extends StatelessWidget {
  final _TrustPoint point;
  const _TrustRow({required this.point});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(point.icon, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  point.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  point.desc,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
