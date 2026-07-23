import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:go_router/go_router.dart';
import '../../core/services/migration_service.dart';
import '../../core/services/user_service.dart';
import '../../core/theme/app_theme.dart';

/// Écran de connexion / inscription — volontairement très simple : juste
/// email + mot de passe (et Google), sans décor. La promesse de l'app se
/// raconte sur l'écran d'accueil qui précède ; ici, on veut juste entrer.
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

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
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
    if (mounted) {
      setState(() => _loading = false);
      context.go('/home');
    }
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
    } catch (_) {
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
    if (mounted) {
      setState(() => _loading = false);
      context.go('/home');
    }
  }

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
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) {
        setState(() {
          _resetSent = true;
          _loading = false;
        });
      }
    } on FirebaseAuthException {
      if (mounted) {
        setState(() {
          _error = 'Email introuvable.';
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
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  onPressed: () =>
                      context.canPop() ? context.pop() : context.go('/welcome'),
                  icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(height: 20),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
