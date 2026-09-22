import 'dart:convert';
import 'dart:math' show Random;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import '../../core/config/app_config.dart';
import '../../core/services/migration_service.dart';
import '../../core/services/tag_service.dart';
import '../../core/services/user_service.dart';
import '../../core/theme/app_theme.dart';

/// Photos d'illustration de l'en-tête (voyage / naissance / famille — thèmes
/// de l'app), une tirée au hasard à chaque ouverture de cet écran (David
/// 22.09.26 : "une photo de ta bibliothèque et ça tourne"). Avant la
/// connexion il n'y a par définition aucun souvenir à montrer (contrairement
/// au dashboard, voir home_screen.dart::_maybePickHero) — banque Unsplash,
/// licence gratuite, aucune attribution requise, URLs vérifiées le 22.09.26
/// (chaque `images.unsplash.com/photo-…` répond 200, image/jpeg).
const _authHeaderPhotos = <String>[
  'https://images.unsplash.com/photo-1543342384-1f1350e27861', // parents + bébé
  'https://images.unsplash.com/photo-1591161555818-7b9debeccc07', // bébé, noir et blanc
  'https://images.unsplash.com/photo-1610901158532-d246c011729e', // enfant, bonnet
  'https://images.unsplash.com/photo-1637184572364-a231e8b4c716', // parents portant bébé
  'https://images.unsplash.com/photo-1581952975975-08cd95a728d4', // couple, mariage
  'https://images.unsplash.com/photo-1562494794-d59c886e2bf2', // famille, mains
  'https://images.unsplash.com/photo-1636830632657-1dcda9360a3a', // parents portant bébé
  'https://images.unsplash.com/photo-1475503572774-15a45e5d60b9', // famille, plage
  'https://images.unsplash.com/photo-1628705250580-80b96d4657f6', // famille, cerf-volant
  'https://images.unsplash.com/photo-1539635278303-d4002c07eae3', // famille, plein air
];

/// Écran de connexion / inscription — le formulaire reste volontairement
/// simple (juste email + mot de passe et Google), mais porte désormais en
/// en-tête une photo illustrative (voir _authHeaderPhotos) plutôt que rien.
class AuthScreen extends StatefulWidget {
  /// 'signup' ouvre directement sur la création de compte ; sinon connexion.
  final String? initialMode;
  const AuthScreen({super.key, this.initialMode});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  late bool _isLogin = widget.initialMode != 'signup';
  bool _loading = false;
  bool _resetSent = false;
  bool _obscurePass = true;
  String? _error;
  String? _versionLabel;
  late final String _headerPhoto =
      _authHeaderPhotos[Random().nextInt(_authHeaderPhotos.length)];

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _versionLabel = 'v${info.version} (${info.buildNumber})');
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  /// `/onboarding/people` si l'utilisateur n'a encore aucune personne (donc
  /// à la création d'un compte), sinon `/home` directement — un compte
  /// existant qui se reconnecte a déjà passé cette étape.
  Future<String> _postAuthRoute() async {
    try {
      final tags = await TagService.myTags();
      final hasPerson =
          tags.any((t) => t.kind == 'personne' || t.kind == 'enfant');
      return hasPerson ? '/home' : '/onboarding/people';
    } catch (_) {
      return '/home';
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
            email: _emailCtrl.text.trim(), password: _passCtrl.text);
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: _emailCtrl.text.trim(), password: _passCtrl.text);
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _error = _mapError(e.code);
          _loading = false;
        });
      }
      return;
    }
    try {
      await MigrationService.runIfNeeded();
    } catch (_) {}
    try {
      await UserService.onLogin();
    } catch (_) {}
    final route = await _postAuthRoute();
    if (!mounted) return;
    setState(() => _loading = false);
    context.go(route);
  }

  Future<void> _googleSignIn() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final gUser = await GoogleSignIn().signIn();
      if (gUser == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final gAuth = await gUser.authentication;
      await FirebaseAuth.instance.signInWithCredential(
          GoogleAuthProvider.credential(
              accessToken: gAuth.accessToken, idToken: gAuth.idToken));
    } catch (e) {
      // Cause la plus fréquente sur Android : aucune empreinte SHA-1 de
      // l'app enregistrée dans Firebase pour cette clé de signature
      // (google-services.json a alors un oauth_client vide côté Android, et
      // Google Sign-In échoue systématiquement avec ApiException 10). Loggé
      // en clair (pas juste avalé) pour pouvoir diagnostiquer sans device.
      debugPrint('Google Sign-In error: $e');
      if (mounted) {
        setState(() {
          _error = 'Erreur Google Sign-In';
          _loading = false;
        });
      }
      return;
    }
    try {
      await MigrationService.runIfNeeded();
    } catch (_) {}
    try {
      await UserService.onLogin();
    } catch (_) {}
    final route = await _postAuthRoute();
    if (!mounted) return;
    setState(() => _loading = false);
    context.go(route);
  }

  /// Passe par le backend (Resend) plutôt que
  /// `FirebaseAuth.sendPasswordResetEmail` : le relai email par défaut de
  /// Firebase Auth (domaine `*.firebaseapp.com` partagé entre des millions de
  /// projets) atterrit trop souvent en spam ou n'arrive jamais — signalé par
  /// David le 03.09.26. Le lien généré reste le vrai lien Firebase
  /// (`Admin SDK generatePasswordResetLink`, backend uniquement) ; seul
  /// l'envoi change. Pas de token Firebase à ce stade (utilisateur
  /// déconnecté) : appel HTTP direct, pas `BackendClient` (qui exige un
  /// utilisateur connecté).
  Future<void> _resetPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Saisis ton email d\'abord.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/notify/reset-password'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email}),
          )
          .timeout(const Duration(seconds: 20));
      if (mounted) {
        setState(() {
          _resetSent = response.statusCode == 200;
          _error = response.statusCode == 200
              ? null
              : 'Une erreur est survenue. Réessaie.';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Une erreur est survenue. Réessaie.';
          _loading = false;
        });
      }
    }
  }

  String _mapError(String code) => switch (code) {
        'user-not-found' => 'Aucun compte avec cet email.',
        'wrong-password' ||
        'invalid-credential' =>
          'Email ou mot de passe incorrect.',
        'email-already-in-use' => 'Cet email est déjà utilisé.',
        'weak-password' => 'Mot de passe trop faible (6 caractères min).',
        _ => 'Une erreur est survenue. Réessaie.',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          SizedBox(
            height: 220,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: '$_headerPhoto?auto=format&fit=crop&w=900&q=70',
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const ColoredBox(color: AppColors.surface),
                  errorWidget: (_, __, ___) => const ColoredBox(color: AppColors.surface),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.35),
                        Colors.black.withOpacity(0.15),
                        Colors.black.withOpacity(0.65),
                      ],
                      stops: const [0, 0.5, 1],
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 0, 0),
                      child: GestureDetector(
                        onTap: () => context.canPop()
                            ? context.pop()
                            : context.go('/welcome'),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.18),
                              shape: BoxShape.circle),
                          child: const Icon(Icons.arrow_back,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 18,
                  child: Row(
                    children: [
                      const Text('carnet',
                          style: TextStyle(
                            fontFamily: 'Fraunces',
                            fontStyle: FontStyle.italic,
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            height: 1,
                          )),
                      const Text('.',
                          style: TextStyle(
                            fontFamily: 'Fraunces',
                            fontStyle: FontStyle.italic,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: AppColors.sageDark,
                            height: 1,
                          )),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_isLogin ? 'Bon retour' : 'Créer un compte',
                          style: const TextStyle(
                            fontFamily: 'Fraunces',
                            fontWeight: FontWeight.w600,
                            fontSize: 30,
                            color: AppColors.textDark,
                          )),
                const SizedBox(height: 6),
                Text(
                  _isLogin
                      ? 'Retrouve tes carnets.'
                      : 'Commence à capturer tes souvenirs.',
                  style: const TextStyle(color: AppColors.textMedium, fontSize: 14.5),
                ),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) =>
                      v == null || !v.contains('@') ? 'Email invalide' : null,
                  decoration: const InputDecoration(hintText: 'Email'),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _passCtrl,
                  obscureText: _obscurePass,
                  validator: (v) =>
                      v == null || v.length < 6 ? '6 caractères minimum' : null,
                  decoration: InputDecoration(
                    hintText: 'Mot de passe',
                    suffixIcon: IconButton(
                      onPressed: () =>
                          setState(() => _obscurePass = !_obscurePass),
                      icon: Icon(
                        _obscurePass
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: AppColors.textMedium,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    const Icon(Icons.error_outline,
                        color: AppColors.error, size: 15),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(_error!,
                            style: const TextStyle(
                                color: AppColors.error, fontSize: 12.5))),
                  ]),
                  // "Email ou mot de passe incorrect" ne distingue jamais
                  // (volontairement, anti-énumération) un vrai mauvais mot de
                  // passe d'un compte créé uniquement via Google, qui n'en a
                  // jamais eu — rappel discret plutôt que de laisser deviner
                  // (confusion vécue par David le 03.09.26).
                  if (_isLogin) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Connecté d\'habitude avec Google ? Utilise le bouton '
                      'ci-dessous.',
                      style:
                          TextStyle(color: AppColors.textMedium, fontSize: 12),
                    ),
                  ],
                ],
                if (_resetSent) ...[
                  const SizedBox(height: 12),
                  Row(children: const [
                    Icon(Icons.check_circle_outline,
                        color: AppColors.sageDark, size: 15),
                    SizedBox(width: 6),
                    Text('Email de réinitialisation envoyé.',
                        style: TextStyle(color: AppColors.sageDark, fontSize: 12.5)),
                  ]),
                ],
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: _loading
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      : ElevatedButton(
                          onPressed: _submit,
                          child: Text(_isLogin ? 'Se connecter' : "S'inscrire"),
                        ),
                ),
                if (_isLogin)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _loading ? null : _resetPassword,
                      child: const Text('Mot de passe oublié ?',
                          style: TextStyle(fontSize: 13.5)),
                    ),
                  )
                else
                  const SizedBox(height: 8),
                Row(children: [
                  const Expanded(child: Divider(color: AppColors.border)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text('ou',
                        style: TextStyle(color: AppColors.textMedium.withOpacity(0.8), fontSize: 12.5)),
                  ),
                  const Expanded(child: Divider(color: AppColors.border)),
                ]),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _loading ? null : _googleSignIn,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: const BoxDecoration(
                              color: Color(0xFF4285F4), shape: BoxShape.circle),
                          child: const Center(
                            child: Text('G',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12)),
                          ),
                        ),
                        const SizedBox(width: 11),
                        const Text('Continuer avec Google'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                GestureDetector(
                  onTap: () => setState(() {
                    _isLogin = !_isLogin;
                    _error = null;
                    _resetSent = false;
                  }),
                  child: Center(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textMedium),
                        children: [
                          TextSpan(
                              text: _isLogin
                                  ? 'Pas encore de compte ?  '
                                  : 'Déjà un compte ?  '),
                          TextSpan(
                            text: _isLogin ? 'S\'inscrire' : 'Se connecter',
                            style: const TextStyle(
                              color: AppColors.sageDark,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_versionLabel != null) ...[
                  const SizedBox(height: 22),
                  Center(
                    child: Text(_versionLabel!,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textMedium.withOpacity(0.6))),
                  ),
                ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
