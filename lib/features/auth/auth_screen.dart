import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/migration_service.dart';
import '../../core/services/user_service.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isLogin = true;
  bool _loading = false;
  bool _resetSent = false;
  bool _obscurePass = true;
  String? _error;

  static const _words = ['voyage', 'famille', 'grossesse', 'enfant', 'souvenirs'];
  int _wordIdx = 0;
  Timer? _timer;

  static const _darkGreen = Color(0xFF1C3D2B);
  static const _midGreen = Color(0xFF3A6648);
  static const _lightGreen = Color(0xFF5C8A6A);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() => _wordIdx = (_wordIdx + 1) % _words.length);
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });
    try {
      if (_isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailCtrl.text.trim(), password: _passCtrl.text);
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _emailCtrl.text.trim(), password: _passCtrl.text);
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() { _error = _mapError(e.code); _loading = false; });
      return;
    }
    try { await MigrationService.runIfNeeded(); } catch (_) {}
    try { await UserService.onLogin(); } catch (_) {}
    if (mounted) { setState(() => _loading = false); context.go('/home'); }
  }

  Future<void> _googleSignIn() async {
    setState(() { _loading = true; _error = null; });
    try {
      final gUser = await GoogleSignIn().signIn();
      if (gUser == null) { if (mounted) setState(() => _loading = false); return; }
      final gAuth = await gUser.authentication;
      await FirebaseAuth.instance.signInWithCredential(
        GoogleAuthProvider.credential(
          accessToken: gAuth.accessToken, idToken: gAuth.idToken));
    } catch (_) {
      if (mounted) setState(() { _error = 'Erreur Google Sign-In'; _loading = false; });
      return;
    }
    try { await MigrationService.runIfNeeded(); } catch (_) {}
    try { await UserService.onLogin(); } catch (_) {}
    if (mounted) { setState(() => _loading = false); context.go('/home'); }
  }

  Future<void> _resetPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Saisis ton email d\'abord.'); return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) setState(() { _resetSent = true; _loading = false; });
    } on FirebaseAuthException {
      if (mounted) setState(() { _error = 'Email introuvable.'; _loading = false; });
    }
  }

  String _mapError(String code) => switch (code) {
    'user-not-found' => 'Aucun compte avec cet email.',
    'wrong-password' || 'invalid-credential' => 'Email ou mot de passe incorrect.',
    'email-already-in-use' => 'Cet email est déjà utilisé.',
    'weak-password' => 'Mot de passe trop faible (6 caractères min).',
    _ => 'Une erreur est survenue. Réessaie.',
  };

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: _darkGreen,
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          // ── Hero section ────────────────────────────────────────────────
          Expanded(child: _buildHero()),

          // ── Form card ───────────────────────────────────────────────────
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(0, -kb, 0),
            decoration: const BoxDecoration(
              color: Color(0xFFF5ECD7),
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: _buildForm(),
          ),
        ],
      ),
    );
  }

  Widget _buildHero() {
    return Stack(
      children: [
        // Gradient background
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_darkGreen, _midGreen, _lightGreen],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ),

        // Decorative circles top-right
        Positioned(
          top: -100, right: -100,
          child: Container(
            width: 300, height: 300,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.07), width: 1.5),
            ),
          ),
        ),
        Positioned(
          top: -50, right: -50,
          child: Container(
            width: 180, height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.05),
            ),
          ),
        ),

        // Decorative bottom-left accent
        Positioned(
          bottom: 20, left: -30,
          child: Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.04),
            ),
          ),
        ),

        // Content
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top bar: logo + brand
                Row(
                  children: [
                    Container(
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: SvgPicture.asset(
                          'assets/images/bloom_logo_v3.svg',
                          width: 22, height: 22,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'carnet',
                      style: TextStyle(
                        fontFamily: 'PlayfairDisplay',
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontStyle: FontStyle.italic,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),

                const Spacer(),

                // Rotating word section — hero text
                Text(
                  'Le carnet de',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white.withOpacity(0.65),
                    letterSpacing: 0.3,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 2),

                // Thin separator
                Container(
                  width: 40, height: 1.5,
                  color: Colors.white.withOpacity(0.3),
                  margin: const EdgeInsets.only(bottom: 10),
                ),

                // The big rotating word
                SizedBox(
                  height: 68,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    transitionBuilder: (child, anim) {
                      final slide = Tween<Offset>(
                        begin: const Offset(0, 0.6),
                        end: Offset.zero,
                      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
                      return ClipRect(
                        child: SlideTransition(
                          position: slide,
                          child: FadeTransition(opacity: anim, child: child),
                        ),
                      );
                    },
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _words[_wordIdx],
                        key: ValueKey(_wordIdx),
                        style: const TextStyle(
                          fontFamily: 'PlayfairDisplay',
                          fontSize: 54,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          fontStyle: FontStyle.italic,
                          height: 1.05,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        28, 12, 28, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 38, height: 4,
              margin: const EdgeInsets.only(bottom: 22),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Title
          Text(
            _isLogin ? 'Bon retour !' : 'Créer un compte',
            style: const TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1C2D22),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _isLogin
                ? 'Retrouve tes carnets et continue l\'aventure.'
                : 'Commence à capturer tes premiers souvenirs.',
            style: TextStyle(
              color: AppColors.textMedium.withOpacity(0.85),
              fontSize: 13, height: 1.4,
            ),
          ),
          const SizedBox(height: 20),

          // Form
          Form(
            key: _formKey,
            child: Column(
              children: [
                _AuthField(
                  controller: _emailCtrl,
                  label: 'Email',
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) => v == null || !v.contains('@') ? 'Email invalide' : null,
                ),
                const SizedBox(height: 10),
                _AuthField(
                  controller: _passCtrl,
                  label: 'Mot de passe',
                  obscure: _obscurePass,
                  suffix: GestureDetector(
                    onTap: () => setState(() => _obscurePass = !_obscurePass),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(
                        _obscurePass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: AppColors.textMedium, size: 19,
                      ),
                    ),
                  ),
                  validator: (v) => v == null || v.length < 6 ? '6 caractères minimum' : null,
                ),

                // Error / success
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    const Icon(Icons.error_outline, color: AppColors.error, size: 15),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 12))),
                  ]),
                ],
                if (_resetSent) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _midGreen.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(children: [
                      Icon(Icons.check_circle_outline, color: _midGreen, size: 15),
                      SizedBox(width: 8),
                      Text('Email de réinitialisation envoyé !',
                        style: TextStyle(color: _midGreen, fontSize: 12)),
                    ]),
                  ),
                ],

                const SizedBox(height: 18),

                // Main CTA
                SizedBox(
                  width: double.infinity,
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : ElevatedButton(
                          onPressed: _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _darkGreen,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                          ),
                          child: Text(_isLogin ? 'Se connecter' : "S'inscrire"),
                        ),
                ),

                if (_isLogin) ...[
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _loading ? null : _resetPassword,
                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 4)),
                      child: const Text('Mot de passe oublié ?',
                        style: TextStyle(color: AppColors.textMedium, fontSize: 12)),
                    ),
                  ),
                ] else const SizedBox(height: 8),

                // Divider
                Row(children: [
                  const Expanded(child: Divider(color: Color(0xFFDDD8CC))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text('ou', style: TextStyle(
                      color: AppColors.textMedium.withOpacity(0.6), fontSize: 12)),
                  ),
                  const Expanded(child: Divider(color: Color(0xFFDDD8CC))),
                ]),
                const SizedBox(height: 10),

                // Google
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _loading ? null : _googleSignIn,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: Color(0xFFDDD8CC)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      backgroundColor: Colors.white,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 20, height: 20,
                          decoration: const BoxDecoration(
                            color: Color(0xFF4285F4),
                            shape: BoxShape.circle,
                          ),
                          child: const Center(
                            child: Text('G', style: TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text('Continuer avec Google',
                          style: TextStyle(
                            color: Color(0xFF1C2D22), fontWeight: FontWeight.w500, fontSize: 14)),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 18),

                // Toggle
                GestureDetector(
                  onTap: () => setState(() { _isLogin = !_isLogin; _error = null; _resetSent = false; }),
                  child: Center(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 13, color: AppColors.textMedium),
                        children: [
                          TextSpan(text: _isLogin ? 'Pas encore de compte ?  ' : 'Déjà un compte ?  '),
                          TextSpan(
                            text: _isLogin ? 'S\'inscrire' : 'Se connecter',
                            style: const TextStyle(
                              color: _midGreen,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.underline,
                              decorationColor: _midGreen,
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _AuthField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final TextInputType? keyboardType;
  final bool obscure;
  final Widget? suffix;
  final String? Function(String?)? validator;

  const _AuthField({
    required this.controller,
    required this.label,
    this.keyboardType,
    this.obscure = false,
    this.suffix,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFDDD8CC)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFDDD8CC)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF3A6648), width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.error),
        ),
      ),
    );
  }
}
