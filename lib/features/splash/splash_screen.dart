import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/media_migration_service.dart';
import '../../core/services/migration_service.dart';
import '../../core/services/tag_migration_service.dart';
import '../../core/services/tag_service.dart';
import '../../core/services/user_service.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeIn;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fadeIn = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _scale = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    _controller.forward();
    _navigate();
  }

  Future<void> _navigate() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try { await MigrationService.runIfNeeded(); } catch (_) {}
      // Carnets → tags (une fois par compte, avant le premier rendu du dashboard).
      try { await TagMigrationService.runIfNeeded(); } catch (_) {}
      // Tags en double fusionnés + nature (année / lieu) rétablie.
      try { await TagService.repairTags(); } catch (_) {}
      try { await UserService.onLogin(); } catch (_) {}
      // Médias restés sur Firebase Storage → R2, en tâche de fond (sans bloquer
      // le démarrage : la migration reprend là où elle s'est arrêtée).
      MediaMigrationService.runInBackground();
      if (!mounted) return;
      context.go('/home');
    } else {
      // Non connecté → l'onboarding (le livre, la voix, les générations,
      // la collection), qui mène ensuite à la création de compte / connexion.
      context.go('/welcome');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.sage,
      body: Center(
        child: FadeTransition(
          opacity: _fadeIn,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SvgPicture.asset(
                  'assets/images/bloom_logo_v3.svg',
                  width: 160,
                  height: 160,
                ),
                const SizedBox(height: 16),
                const Text(
                  'carnet',
                  style: TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    color: AppColors.cream,
                    letterSpacing: 2,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Chaque histoire mérite d\'être racontée.',
                  style: TextStyle(
                    fontFamily: 'DMSans',
                    fontSize: 14,
                    color: AppColors.cream.withOpacity(0.8),
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
