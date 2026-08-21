import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../core/services/media_migration_service.dart';
import '../../core/services/migration_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/shared_media_service.dart';
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
      // Raccourcis « Ajouter à … » du menu de partage, rafraîchis à chaque
      // démarrage (sans bloquer : c'est du confort, pas du chemin critique).
      _refreshShareShortcuts();
      // Jeton de notification : il peut changer tout seul, on le remet à jour
      // pour ceux qui ont déjà accepté. N'affiche aucune demande.
      NotificationService.syncOnLogin();
      if (!mounted) return;
      // Appli ouverte depuis « Partager » (Google Photos, galerie…) : on va
      // droit au formulaire de souvenir, les médias reçus déjà attachés. Si le
      // partage est passé par un raccourci de tag, ce tag est pré-coché.
      if (await SharedMediaService.hasPending()) {
        if (!mounted) return;
        final tagId = SharedMediaService.pendingTagId;
        context.go(
          '/memory/new?shared=1${tagId != null ? '&tag=$tagId' : ''}',
        );
        return;
      }
      // Appli ouverte en tapant une notification « souvenir du jour » : on va
      // droit au souvenir en question.
      final memoryId = await NotificationService.initialMemoryId();
      if (!mounted) return;
      if (memoryId != null) {
        context.go('/memory/$memoryId');
        return;
      }
      context.go('/home');
    } else {
      // Non connecté → l'onboarding (le livre, la voix, les générations,
      // la collection), qui mène ensuite à la création de compte / connexion.
      context.go('/welcome');
    }
  }

  /// Un raccourci de partage par tag, les tags « enfant » d'abord (ce sont eux
  /// qu'on vise le plus souvent), puis les autres par ordre alphabétique.
  /// Android n'en affiche qu'une poignée, le tri compte donc autant que la liste.
  Future<void> _refreshShareShortcuts() async {
    try {
      final tags = await TagService.visibleTags();
      final ordered = [
        ...tags.where((t) => t.isChild),
        ...tags.where((t) => !t.isChild),
      ];
      await SharedMediaService.publishShortcuts(
        [for (final t in ordered) (id: t.id, label: t.label)],
      );
    } catch (_) {
      // Pas de raccourcis : le partage classique marche toujours.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Identité "livre-cœur" (assets/branding/) : palette dédiée à l'écran de
  // démarrage, distincte du thème sombre espresso du reste de l'app.
  static const _terracotta = Color(0xFFD0806A);
  static const _cream = Color(0xFFFBF4EF);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _terracotta,
      body: Center(
        child: FadeTransition(
          opacity: _fadeIn,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SvgPicture.asset(
                  'assets/branding/svg/carnet-mark.svg',
                  width: 140,
                  height: 140,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Carnet album souvenir',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: _cream,
                    letterSpacing: 1,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Chaque histoire mérite d\'être racontée.',
                  style: TextStyle(
                    fontFamily: 'DMSans',
                    fontSize: 14,
                    color: _cream.withOpacity(0.85),
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
