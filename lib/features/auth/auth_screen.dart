import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:go_router/go_router.dart';
import '../../core/services/migration_service.dart';
import '../../core/services/user_service.dart';

/// Écran de connexion / inscription — design "wow" : fond aurora animé, deck de
/// polaroids (vraies photos d'exemple tirées au hasard à chaque arrivée), titre
/// doré brillant, et feuille crème avec les badges de confiance.
class AuthScreen extends StatefulWidget {
  /// 'signup' ouvre directement sur la création de compte ; sinon connexion.
  final String? initialMode;
  const AuthScreen({super.key, this.initialMode});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  late bool _isLogin = widget.initialMode != 'signup';
  bool _loading = false;
  bool _resetSent = false;
  bool _obscurePass = true;
  String? _error;

  // Palette (reprise de la maquette carnet-login-wow).
  static const _green900 = Color(0xFF1A2D23);
  static const _green800 = Color(0xFF2C4636);
  static const _green700 = Color(0xFF3D5A48);
  static const _green600 = Color(0xFF4F7059);
  static const _cream = Color(0xFFF2EAD6);
  static const _ink = Color(0xFF233028);
  static const _muted = Color(0xFF7A8A7E);
  static const _gold = Color(0xFFD8B676);

  // Photos d'exemple intégrées (assets/welcome/). Aucune donnée privée.
  static const _allPhotos = [
    'assets/welcome/m01.jpg', 'assets/welcome/m02.jpg',
    'assets/welcome/m03.jpg', 'assets/welcome/m04.jpg',
    'assets/welcome/m05.jpg', 'assets/welcome/m06.jpg',
    'assets/welcome/m07.jpg', 'assets/welcome/m08.jpg',
    'assets/welcome/m09.jpg', 'assets/welcome/m10.jpg',
    'assets/welcome/m11.jpg', 'assets/welcome/m12.jpg',
  ];

  // 4 emplacements de polaroids (cluster haut-droite), inspirés de la maquette.
  static const _slots = <_Slot>[
    _Slot(top: 58, right: 12, w: 118, h: 140, rot: 0.16, depth: 22, phase: 0.15),
    _Slot(top: 150, right: 92, w: 90, h: 106, rot: -0.21, depth: 16, phase: 0.35),
    _Slot(top: 36, right: 116, w: 82, h: 98, rot: -0.07, depth: 11, phase: 0.5),
    _Slot(top: 172, right: 4, w: 72, h: 86, rot: 0.26, depth: 8, phase: 0.62),
  ];

  late final List<String> _deck; // 4 photos tirées au hasard
  late final AnimationController _aurora;
  late final AnimationController _shine;
  late final AnimationController _float;
  late final AnimationController _enter;
  Offset _parallax = Offset.zero;

  @override
  void initState() {
    super.initState();
    // Aléatoire à chaque arrivée sur l'écran.
    _deck = (List<String>.from(_allPhotos)..shuffle()).take(4).toList();
    _aurora = AnimationController(
        vsync: this, duration: const Duration(seconds: 18))
      ..repeat(reverse: true);
    _shine = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 4500))
      ..repeat();
    _float = AnimationController(
        vsync: this, duration: const Duration(seconds: 7))
      ..repeat(reverse: true);
    _enter = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 950))
      ..forward();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _aurora.dispose();
    _shine.dispose();
    _float.dispose();
    _enter.dispose();
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
    final kb = MediaQuery.of(context).viewInsets.bottom;
    return Scaffold(
      backgroundColor: _green900,
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          Expanded(child: _buildHero()),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(0, -kb, 0),
            decoration: const BoxDecoration(
              color: _cream,
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: _buildForm(),
          ),
        ],
      ),
    );
  }

  // ── Hero : aurora + deck de polaroids + titre doré ─────────────────────────
  Widget _buildHero() {
    return ClipRect(
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          _parallax = Offset(
            (_parallax.dx + d.delta.dx).clamp(-24.0, 24.0),
            (_parallax.dy + d.delta.dy).clamp(-16.0, 16.0),
          );
        }),
        onPanEnd: (_) => setState(() => _parallax = Offset.zero),
        child: Stack(
          children: [
            // Fond aurora animé
            Positioned.fill(child: _buildAurora()),
            // Deck de polaroids
            for (var i = 0; i < _slots.length; i++)
              _buildPolaroid(_slots[i], _deck[i], i),
            // Marque + titre
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(26, 16, 26, 26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.13),
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                                color: Colors.white.withOpacity(0.18)),
                          ),
                          child: Center(
                            child: SvgPicture.asset(
                                'assets/images/bloom_logo_v3.svg',
                                width: 23,
                                height: 23),
                          ),
                        ),
                        const SizedBox(width: 11),
                        const Text('carnet',
                            style: TextStyle(
                              fontFamily: 'PlayfairDisplay',
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.bold,
                              fontSize: 23,
                              color: Colors.white,
                            )),
                      ],
                    ),
                    const Spacer(),
                    Text('Le carnet de',
                        style: TextStyle(
                          fontSize: 19,
                          color: Colors.white.withOpacity(0.82),
                        )),
                    Container(
                      width: 46,
                      height: 2,
                      margin: const EdgeInsets.only(top: 6, bottom: 6),
                      color: _gold,
                    ),
                    _buildShineTitle(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAurora() {
    return AnimatedBuilder(
      animation: _aurora,
      builder: (context, _) {
        final t = _aurora.value; // 0..1 (reverse)
        return Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_green700, _green900],
                  ),
                ),
              ),
            ),
            // Blobs lumineux qui dérivent
            _auroraBlob(
              align: Alignment(-0.6 + t * 0.3, -0.5 + t * 0.2),
              size: 320,
              color: _green600.withOpacity(0.55),
            ),
            _auroraBlob(
              align: Alignment(0.7 - t * 0.25, -0.7 + t * 0.15),
              size: 260,
              color: const Color(0xFF4A6A54).withOpacity(0.5),
            ),
            _auroraBlob(
              align: Alignment(0.2 + t * 0.2, 0.7 - t * 0.2),
              size: 300,
              color: _green800.withOpacity(0.6),
            ),
          ],
        );
      },
    );
  }

  Widget _auroraBlob(
      {required Alignment align, required double size, required Color color}) {
    return Align(
      alignment: align,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withOpacity(0)],
          ),
        ),
      ),
    );
  }

  Widget _buildShineTitle() {
    return AnimatedBuilder(
      animation: _shine,
      builder: (context, child) {
        final t = _shine.value;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment(-1.0 + 3.0 * t, 0),
            end: Alignment(-0.4 + 3.0 * t, 0),
            colors: const [Colors.white, _gold, Colors.white],
            stops: const [0.35, 0.5, 0.65],
          ).createShader(rect),
          child: child,
        );
      },
      child: const Text('souvenirs',
          style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w900,
            fontSize: 56,
            height: 0.95,
            letterSpacing: -1,
            color: Colors.white,
          )),
    );
  }

  Widget _buildPolaroid(_Slot s, String asset, int index) {
    return AnimatedBuilder(
      animation: Listenable.merge([_float, _enter]),
      builder: (context, _) {
        // Entrée décalée par polaroid
        final start = 0.1 * index;
        final e = ((_enter.value - start) / (1 - start)).clamp(0.0, 1.0);
        final eased = Curves.easeOutCubic.transform(e);
        // Flottement continu (déphasé)
        final bob = math.sin((_float.value + s.phase) * math.pi * 2) * 6;
        return Positioned(
          top: s.top - _parallax.dy * (s.depth / 22) + (1 - eased) * 26,
          right: s.right + _parallax.dx * (s.depth / 22),
          child: Opacity(
            opacity: eased,
            child: Transform.translate(
              offset: Offset(0, bob),
              child: Transform.rotate(
                angle: s.rot,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.4),
                        blurRadius: 26,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(1),
                    child: Image.asset(
                      asset,
                      width: s.w,
                      height: s.h,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Feuille crème : formulaire + badges de confiance ───────────────────────
  Widget _buildForm() {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          28, 12, 28, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 5,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color: const Color(0xFFD3C8AC),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ),
          Text(_isLogin ? 'Bon retour !' : 'Créer un compte',
              style: const TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontWeight: FontWeight.w800,
                fontSize: 32,
                color: _ink,
                height: 1,
              )),
          const SizedBox(height: 8),
          Text(
            _isLogin
                ? 'Retrouve tes carnets et continue l\'aventure.'
                : 'Commence à capturer tes premiers souvenirs.',
            style: const TextStyle(color: _muted, fontSize: 14.5, height: 1.35),
          ),

          // Badges de confiance
          const SizedBox(height: 20),
          Row(
            children: [
              const Text('TES SOUVENIRS, PROTÉGÉS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    color: Color(0xFFA8844F),
                  )),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                    height: 1,
                    color: _gold.withOpacity(0.4)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFECE2C9), Color(0xFFE5DBC0)],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFDDD0B0)),
            ),
            child: const Row(
              children: [
                _TrustBadge(icon: Icons.lock_outline, label: 'Privé\npar défaut'),
                _TrustDivider(),
                _TrustBadge(
                    icon: Icons.verified_user_outlined,
                    label: 'Connexion\nsécurisée'),
                _TrustDivider(),
                _TrustBadge(
                    icon: Icons.import_export, label: 'Export &\nsuppression'),
              ],
            ),
          ),

          const SizedBox(height: 18),
          Form(
            key: _formKey,
            child: Column(
              children: [
                _AuthField(
                  controller: _emailCtrl,
                  hint: 'Email',
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) =>
                      v == null || !v.contains('@') ? 'Email invalide' : null,
                ),
                const SizedBox(height: 12),
                _AuthField(
                  controller: _passCtrl,
                  hint: 'Mot de passe',
                  obscure: _obscurePass,
                  suffix: GestureDetector(
                    onTap: () => setState(() => _obscurePass = !_obscurePass),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 14),
                      child: Icon(
                        _obscurePass
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: _muted,
                        size: 20,
                      ),
                    ),
                  ),
                  validator: (v) =>
                      v == null || v.length < 6 ? '6 caractères minimum' : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    const Icon(Icons.error_outline,
                        color: Color(0xFFC0392B), size: 15),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(_error!,
                            style: const TextStyle(
                                color: Color(0xFFC0392B), fontSize: 12.5))),
                  ]),
                ],
                if (_resetSent) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _green700.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(children: [
                      Icon(Icons.check_circle_outline,
                          color: _green700, size: 15),
                      SizedBox(width: 8),
                      Text('Email de réinitialisation envoyé !',
                          style: TextStyle(color: _green700, fontSize: 12.5)),
                    ]),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : ElevatedButton(
                          onPressed: _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _green700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 17),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                            textStyle: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16.5),
                          ),
                          child: Text(_isLogin ? 'Se connecter' : "S'inscrire"),
                        ),
                ),
                if (_isLogin)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _loading ? null : _resetPassword,
                      child: const Text('Mot de passe oublié ?',
                          style: TextStyle(color: _green700, fontSize: 13.5)),
                    ),
                  )
                else
                  const SizedBox(height: 8),
                Row(children: [
                  const Expanded(child: Divider(color: Color(0xFFDDD2B6))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text('ou',
                        style: TextStyle(
                            color: _muted.withOpacity(0.8), fontSize: 12.5)),
                  ),
                  const Expanded(child: Divider(color: Color(0xFFDDD2B6))),
                ]),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _loading ? null : _googleSignIn,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      side: const BorderSide(color: Color(0xFFE6DDC6)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      backgroundColor: Colors.white,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: const BoxDecoration(
                              color: Color(0xFF4285F4), shape: BoxShape.circle),
                          child: const Center(
                            child: Text('G',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13)),
                          ),
                        ),
                        const SizedBox(width: 11),
                        const Text('Continuer avec Google',
                            style: TextStyle(
                                color: _ink,
                                fontWeight: FontWeight.w600,
                                fontSize: 15)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: () => setState(() {
                    _isLogin = !_isLogin;
                    _error = null;
                    _resetSent = false;
                  }),
                  child: Center(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 14, color: _muted),
                        children: [
                          TextSpan(
                              text: _isLogin
                                  ? 'Pas encore de compte ?  '
                                  : 'Déjà un compte ?  '),
                          TextSpan(
                            text: _isLogin ? 'S\'inscrire' : 'Se connecter',
                            style: const TextStyle(
                              color: _green800,
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
        ],
      ),
    );
  }
}

class _Slot {
  final double top, right, w, h, rot, depth, phase;
  const _Slot({
    required this.top,
    required this.right,
    required this.w,
    required this.h,
    required this.rot,
    required this.depth,
    required this.phase,
  });
}

class _TrustBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TrustBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF3D5A48), Color(0xFF1A2D23)],
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 9),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: Color(0xFF233028),
              )),
        ],
      ),
    );
  }
}

class _TrustDivider extends StatelessWidget {
  const _TrustDivider();
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 58, color: const Color(0xFFD9CDB1));
}

class _AuthField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final bool obscure;
  final Widget? suffix;
  final String? Function(String?)? validator;

  const _AuthField({
    required this.controller,
    required this.hint,
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
      style: const TextStyle(fontSize: 16, color: Color(0xFF233028)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF9AA89D)),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF4F7059), width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFC0392B)),
        ),
      ),
    );
  }
}
