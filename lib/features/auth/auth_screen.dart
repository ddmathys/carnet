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
  // Palette terracotta (mêmes noms `_green*` conservés — valeurs corail/chaud
  // pour harmoniser le login avec le reste de l'app).
  static const _green900 = Color(0xFF3E2C25); // brun chaud — bas du héros
  static const _green800 = Color(0xFF6B4A3C);
  static const _green700 = Color(0xFFD9725A); // corail foncé — CTA principal
  static const _green600 = Color(0xFFE8896B); // corail
  static const _cream = Color(0xFFFBF6F1);
  static const _ink = Color(0xFF33302E);
  static const _muted = Color(0xFF8B8480);
  static const _gold = Color(0xFFCBA876);

  // Photos d'exemple intégrées (assets/welcome/). Aucune donnée privée.
  static const _allPhotos = [
    'assets/welcome/m01.jpg', 'assets/welcome/m02.jpg',
    'assets/welcome/m03.jpg', 'assets/welcome/m04.jpg',
    'assets/welcome/m05.jpg', 'assets/welcome/m06.jpg',
    'assets/welcome/m07.jpg', 'assets/welcome/m08.jpg',
    'assets/welcome/m09.jpg', 'assets/welcome/m10.jpg',
    'assets/welcome/m11.jpg', 'assets/welcome/m12.jpg',
  ];

  // 5 polaroids répartis dans le héros (cluster haut-droite + une photo à
  // gauche pour un rendu plus imagé), inspirés de la maquette.
  static const _slots = <_Slot>[
    _Slot(top: 74, right: 14, w: 128, h: 152, rot: 0.15, depth: 22, phase: 0.15),
    _Slot(top: 186, right: 104, w: 98, h: 116, rot: -0.20, depth: 16, phase: 0.35),
    _Slot(top: 44, right: 132, w: 88, h: 104, rot: -0.07, depth: 11, phase: 0.5),
    _Slot(top: 210, right: 6, w: 80, h: 94, rot: 0.24, depth: 8, phase: 0.62),
    _Slot(top: 128, right: 214, w: 76, h: 90, rot: -0.16, depth: 6, phase: 0.28),
  ];

  late final List<String> _deck; // 5 photos tirées au hasard
  late final AnimationController _aurora;
  late final AnimationController _shine;
  late final AnimationController _float;
  late final AnimationController _enter;
  Offset _parallax = Offset.zero;

  @override
  void initState() {
    super.initState();
    // Aléatoire à chaque arrivée sur l'écran.
    _deck = (List<String>.from(_allPhotos)..shuffle()).take(5).toList();
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

  // Détail « Tes souvenirs, protégés » — en option depuis le login (remplace
  // l'ancienne page d'accueil imposée aux utilisateurs non connectés).
  void _showSecuritySheet(BuildContext context) {
    const points = <(IconData, String, String)>[
      (
        Icons.lock_outline,
        'Privé par défaut',
        'Chaque carnet n\'est visible que par toi et les proches que tu invites. Personne d\'autre.'
      ),
      (
        Icons.shield_outlined,
        'Photos & vidéos protégées',
        'Stockées de façon privée, accessibles uniquement via des liens sécurisés et temporaires.'
      ),
      (
        Icons.verified_user_outlined,
        'Connexion sécurisée',
        'Via Google ou email, gérée par Firebase. L\'app ne conserve jamais ton mot de passe.'
      ),
      (
        Icons.import_export,
        'Tu gardes le contrôle',
        'Exporte tes souvenirs en livre ou supprime-les définitivement, quand tu veux.'
      ),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _cream,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              const Text('Tes souvenirs, en sécurité',
                  style: TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontWeight: FontWeight.w800,
                    fontSize: 24,
                    color: _ink,
                  )),
              const SizedBox(height: 6),
              const Text(
                'Pensé pour la confidentialité et la transparence.',
                style: TextStyle(color: _muted, fontSize: 14, height: 1.35),
              ),
              const SizedBox(height: 18),
              for (final (icon, title, desc) in points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _green700.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Icon(icon, color: _green700, size: 21),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: const TextStyle(
                                  color: _ink,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                )),
                            const SizedBox(height: 3),
                            Text(desc,
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 13,
                                  height: 1.35,
                                )),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _green700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    textStyle: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15.5),
                  ),
                  child: const Text('Compris'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // Hero à hauteur fixe (généreuse) pour que les photos soient toujours
    // visibles en haut ; tout l'écran défile → l'utilisateur scrolle pour
    // atteindre le formulaire (plus simple que de tout tasser).
    final heroHeight = math.max(430.0, size.height * 0.54);
    return Scaffold(
      backgroundColor: _cream,
      body: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: Column(
          children: [
            SizedBox(height: heroHeight, child: _buildHero()),
            // Feuille crème qui remonte légèrement sur le héros (coins arrondis).
            Transform.translate(
              offset: const Offset(0, -28),
              child: Container(
                decoration: const BoxDecoration(
                  color: _cream,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: _buildForm(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Hero : aurora + deck de polaroids + titre doré ─────────────────────────
  Widget _buildHero() {
    return ClipRect(
      child: GestureDetector(
        // Parallaxe horizontale uniquement : les drags verticaux passent au
        // défilement de la page (sinon le scroll serait capté par le héros).
        onHorizontalDragUpdate: (d) => setState(() {
          _parallax = Offset(
            (_parallax.dx + d.delta.dx).clamp(-24.0, 24.0),
            0,
          );
        }),
        onHorizontalDragEnd: (_) => setState(() => _parallax = Offset.zero),
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
  // (Non scrollable : le défilement est géré par la page entière.)
  Widget _buildForm() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          28, 24, 28, MediaQuery.of(context).padding.bottom + 24),
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

          // Sécurité en option : un lien discret ouvre le détail (plutôt qu'une
          // page « souvenirs protégés » imposée en plein écran).
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => _showSecuritySheet(context),
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFEFE7D2),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFDDD0B0)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline,
                      size: 18, color: Color(0xFFA8844F)),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Tes souvenirs, protégés',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6B5330),
                        )),
                  ),
                  const Text('En savoir plus',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFA8844F),
                      )),
                  const Icon(Icons.chevron_right,
                      size: 18, color: Color(0xFFA8844F)),
                ],
              ),
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
