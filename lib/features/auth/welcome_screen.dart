import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Onboarding immersif affiché aux utilisateurs non connectés : 4 diapositives
/// qui racontent la promesse de l'app (le livre, la voix, les générations,
/// la collection), suivies d'un CTA de création de compte / connexion.
/// Palette et typographie dédiées (distinctes du thème clair du reste de
/// l'app) — c'est un moment de marque, pas un écran fonctionnel.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _Palette {
  static const clay = Color(0xFFB4644D);
  static const terra = Color(0xFFD0806A);
  static const ink = Color(0xFF241E1B);
  static const espresso = Color(0xFF241B16);
  static const cream = Color(0xFFFBF4EF);
  static const brass = Color(0xFFC9A961);
}

const _photos = [
  'assets/welcome/m01.jpg', 'assets/welcome/m02.jpg', 'assets/welcome/m03.jpg',
  'assets/welcome/m04.jpg', 'assets/welcome/m05.jpg', 'assets/welcome/m06.jpg',
  'assets/welcome/m07.jpg', 'assets/welcome/m08.jpg', 'assets/welcome/m09.jpg',
  'assets/welcome/m10.jpg', 'assets/welcome/m11.jpg', 'assets/welcome/m12.jpg',
];

String _photo(int i) => _photos[i % _photos.length];

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _pageController = PageController();
  int _index = 0;
  Timer? _autoTimer;

  static const _slideCount = 4;

  @override
  void initState() {
    super.initState();
    _scheduleAuto();
  }

  void _scheduleAuto() {
    _autoTimer?.cancel();
    _autoTimer = Timer(const Duration(milliseconds: 6400), () {
      if (!mounted) return;
      _goTo((_index + 1) % _slideCount);
    });
  }

  void _goTo(int i) {
    if (!mounted) return;
    setState(() => _index = i);
    _pageController.animateToPage(i,
        duration: const Duration(milliseconds: 720),
        curve: Curves.easeInOutCubic);
    _scheduleAuto();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLight = _index == 2;
    return Scaffold(
      backgroundColor: _Palette.espresso,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                PageView(
                  controller: _pageController,
                  onPageChanged: (i) {
                    setState(() => _index = i);
                    _scheduleAuto();
                  },
                  children: const [
                    _BookSlide(),
                    _RecordSlide(),
                    _GenerationsSlide(),
                    _ShelfSlide(),
                  ],
                ),
                Positioned(
                  top: 26,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(child: _BrandMark(light: isLight)),
                ),
                Positioned(
                  left: 26,
                  bottom: 20,
                  child: _StitchIndicator(
                      index: _index, light: isLight, onTap: _goTo),
                ),
              ],
            ),
          ),
          const _BottomSheetCta(),
        ],
      ),
    );
  }
}

// ── Marque ────────────────────────────────────────────────────────────────

class _BrandMark extends StatelessWidget {
  final bool light;
  const _BrandMark({required this.light});

  @override
  Widget build(BuildContext context) {
    final color = light ? _Palette.ink : Colors.white;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: const Text('📖', style: TextStyle(fontSize: 14)),
        ),
        const SizedBox(width: 9),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 400),
          style: TextStyle(
            fontFamily: 'Fraunces',
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w700,
            fontSize: 20,
            color: color,
          ),
          child: const Text('carnet'),
        ),
      ],
    );
  }
}

// ── Navigation « couture » (points sur ligne pointillée) ────────────────────

class _StitchIndicator extends StatelessWidget {
  final int index;
  final bool light;
  final ValueChanged<int> onTap;
  const _StitchIndicator(
      {required this.index, required this.light, required this.onTap});

  static const _positions = [8.0, 61.0, 114.0, 168.0];

  @override
  Widget build(BuildContext context) {
    final base =
        light ? _Palette.ink.withOpacity(0.28) : Colors.white.withOpacity(0.3);
    return SizedBox(
      width: 176,
      height: 22,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          CustomPaint(
            size: const Size(176, 22),
            painter: _DashedLinePainter(color: base),
          ),
          for (var i = 0; i < _positions.length; i++)
            Positioned(
              left: _positions[i] - 9,
              top: 2,
              child: GestureDetector(
                onTap: () => onTap(i),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: i == index ? 7.5 : 5,
                      height: i == index ? 7.5 : 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i <= index ? _Palette.terra : base,
                      ),
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

class _DashedLinePainter extends CustomPainter {
  final Color color;
  const _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const dashWidth = 13.0;
    const dashGap = 9.0;
    const y = 11.0;
    double x = 8;
    while (x < size.width - 8) {
      final end = math.min(x + dashWidth, size.width - 8);
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x += dashWidth + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}

// ── Feuille du bas : confiance + CTA ─────────────────────────────────────────

class _BottomSheetCta extends StatelessWidget {
  const _BottomSheetCta();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _Palette.espresso,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('🔒 ',
                    style:
                        TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.4))),
                Text('Privé par défaut',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.62), fontSize: 11.5)),
              ],
            ),
            const SizedBox(height: 15),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => context.push('/auth?mode=signup'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _Palette.terra,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                  textStyle: const TextStyle(
                      fontFamily: 'Outfit', fontWeight: FontWeight.w500, fontSize: 15),
                ),
                child: const Text('Créer mon carnet — gratuit'),
              ),
            ),
            const SizedBox(height: 9),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => context.push('/auth?mode=login'),
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white.withOpacity(0.07),
                  foregroundColor: Colors.white.withOpacity(0.88),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                  textStyle: const TextStyle(
                      fontFamily: 'Outfit', fontWeight: FontWeight.w500, fontSize: 15),
                ),
                child: const Text('J\'ai déjà un carnet'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Texte de chaque diapositive ──────────────────────────────────────────────

class _SlideCopy extends StatelessWidget {
  final String line1;
  final String line2Plain;
  final String line2Em;
  final String body;
  final bool light;
  const _SlideCopy({
    required this.line1,
    required this.line2Plain,
    required this.line2Em,
    required this.body,
    this.light = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = light ? _Palette.ink : Colors.white;
    final emColor = light ? _Palette.clay : const Color(0xFFF6DFC4);
    final bodyColor = light ? const Color(0xFF7A6A60) : Colors.white.withOpacity(0.66);
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 0, 26, 68),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: TextStyle(
                fontFamily: 'Fraunces',
                fontSize: 27,
                fontWeight: FontWeight.w700,
                height: 1.1,
                letterSpacing: -0.3,
                color: color,
              ),
              children: [
                TextSpan(text: '$line1\n'),
                TextSpan(text: line2Plain),
                TextSpan(
                    text: line2Em,
                    style: TextStyle(fontStyle: FontStyle.italic, color: emColor)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 296),
            child: Text(body,
                style: TextStyle(fontSize: 13, height: 1.5, color: bodyColor)),
          ),
        ],
      ),
    );
  }
}

// ── Photo en duotone (niveaux de gris + teinte chaude) ──────────────────────

class _DuoPhoto extends StatelessWidget {
  final String path;
  final BoxFit fit;
  const _DuoPhoto({required this.path, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(_Palette.terra, BlendMode.color),
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: Image.asset(path, fit: fit, width: double.infinity, height: double.infinity),
      ),
    );
  }
}

// ── Diapositive 1 : le mur de photos + le livre qui se remplit ──────────────

class _BookSlide extends StatefulWidget {
  const _BookSlide();

  @override
  State<_BookSlide> createState() => _BookSlideState();
}

class _BookSlideState extends State<_BookSlide> with TickerProviderStateMixin {
  late final AnimationController _polaroids =
      AnimationController(vsync: this, duration: const Duration(seconds: 15))
        ..repeat();

  @override
  void dispose() {
    _polaroids.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const _PhotoWall(),
        // Voile sombre du haut vers le bas, pour lire le texte.
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xB8241B16),
                Color(0x3D241B16),
                Color(0x6B241B16),
                Color(0xF0241B16),
              ],
              stops: [0.0, 0.26, 0.52, 0.86],
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, -0.1),
          child: SizedBox(
            width: 340,
            height: 240,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const _OpenBook(),
                _PolaroidField(controller: _polaroids),
              ],
            ),
          ),
        ),
        const Align(
          alignment: Alignment.bottomLeft,
          child: _SlideCopy(
            line1: 'Vos souvenirs',
            line2Plain: 'deviennent ',
            line2Em: 'un livre',
            body: 'Des milliers de photos dormantes. Celles qui comptent, '
                'imprimées.',
          ),
        ),
      ],
    );
  }
}

/// Trois colonnes de photos défilant lentement (deux montent, une descend) —
/// évoque un mur de souvenirs vivant derrière le livre.
class _PhotoWall extends StatefulWidget {
  const _PhotoWall();

  @override
  State<_PhotoWall> createState() => _PhotoWallState();
}

class _PhotoWallState extends State<_PhotoWall> with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  static const _durations = [58, 66, 74];

  @override
  void initState() {
    super.initState();
    _controllers = [
      for (final s in _durations)
        AnimationController(vsync: this, duration: Duration(seconds: s))..repeat(),
    ];
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const reverse = [false, true, false];
    return ClipRect(
      child: Opacity(
        opacity: 0.5,
        child: Row(
          children: [
            for (var c = 0; c < 3; c++)
              Expanded(
                child: _WallColumn(
                  controller: _controllers[c],
                  reverse: reverse[c],
                  seed: c,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WallColumn extends StatelessWidget {
  final AnimationController controller;
  final bool reverse;
  final int seed;
  const _WallColumn(
      {required this.controller, required this.reverse, required this.seed});

  static const _tileCount = 9;
  static const _tileHeight = 82.0;
  static const _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final tiles = List.generate(_tileCount, (i) => _photo(seed * 4 + i));
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final setHeight = _tileCount * (_tileHeight + _gap);
        final t = reverse ? (1 - controller.value) : controller.value;
        final offset = -t * setHeight;
        return ClipRect(
          child: Stack(
            children: [
              Positioned(
                top: offset,
                left: 0,
                right: 0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(
                    children: [
                      for (final p in [...tiles, ...tiles]) _WallTile(path: p),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WallTile extends StatelessWidget {
  final String path;
  const _WallTile({required this.path});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          height: 82,
          child: Image.asset(path, fit: BoxFit.cover, width: double.infinity),
        ),
      ),
    );
  }
}

/// Livre ouvert stylisé : deux pages avec des photos et lignes de texte.
/// Volontairement en 2D (léger tilt seulement) plutôt qu'en perspective 3D —
/// plus fiable à l'écran, tout en restant lisible comme un livre ouvert.
class _OpenBook extends StatelessWidget {
  const _OpenBook();

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.045,
      child: Container(
        width: 214,
        height: 150,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.55),
                blurRadius: 34,
                offset: const Offset(0, 24)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Row(
            children: [
              Expanded(child: _BookPage(alignRight: false)),
              Container(
                width: 8,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Colors.brown.withOpacity(0.55),
                    Colors.brown.withOpacity(0.05),
                    Colors.brown.withOpacity(0.55),
                  ]),
                ),
              ),
              Expanded(child: _BookPage(alignRight: true)),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookPage extends StatelessWidget {
  final bool alignRight;
  const _BookPage({required this.alignRight});

  @override
  Widget build(BuildContext context) {
    final radius = alignRight
        ? const BorderRadius.horizontal(right: Radius.circular(7))
        : const BorderRadius.horizontal(left: Radius.circular(7));
    return Container(
      height: 150,
      decoration: BoxDecoration(color: const Color(0xFFFFFCF8), borderRadius: radius),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: _DuoPhoto(path: _photo(alignRight ? 3 : 0)),
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < (alignRight ? 4 : 3); i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Container(
                height: 3,
                width: i.isEven ? double.infinity : 60,
                decoration: BoxDecoration(
                  color: const Color(0xFFE4D7CB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Polaroïds qui apparaissent, flottent un instant, puis glissent vers le
/// livre en rétrécissant — « vos souvenirs deviennent un livre ». Quatre
/// photos en boucle décalée (comme l'original : un cycle de 15s, décalées
/// d'un quart de tour chacune).
class _PolaroidField extends StatelessWidget {
  final Animation<double> controller;
  const _PolaroidField({required this.controller});

  static const _specs = [
    (-96.0, -40.0, -0.21, 0),
    (86.0, -56.0, 0.16, 1),
    (-80.0, 46.0, 0.10, 2),
    (90.0, 34.0, -0.14, 3),
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Stack(
          alignment: Alignment.center,
          children: [
            for (final s in _specs)
              _polaroidAt(x: s.$1, y: s.$2, rot: s.$3, delayIndex: s.$4),
          ],
        );
      },
    );
  }

  Widget _polaroidAt(
      {required double x, required double y, required double rot, required int delayIndex}) {
    final phase = (controller.value + delayIndex * 0.25) % 1.0;
    double opacity;
    double scale;
    double dx, dy, rotf;
    if (phase < 0.09) {
      final t = phase / 0.09;
      opacity = t;
      scale = 0.9 + 0.1 * t;
      dx = x;
      dy = y;
      rotf = rot;
    } else if (phase < 0.40) {
      opacity = 1;
      scale = 1;
      dx = x;
      dy = y - 6 * ((phase - 0.09) / 0.31);
      rotf = rot;
    } else if (phase < 0.74) {
      final t = (phase - 0.40) / 0.34;
      opacity = 1;
      scale = 1 - 0.42 * t;
      dx = x * (1 - t);
      dy = y * (1 - t) + 8 * t;
      rotf = rot * (1 - t);
    } else if (phase < 0.86) {
      final t = (phase - 0.74) / 0.12;
      opacity = 1 - 0.55 * t;
      scale = 0.58 - 0.26 * t;
      dx = 0;
      dy = 8 + 18 * t;
      rotf = 0;
    } else {
      final t = (phase - 0.86) / 0.14;
      opacity = 0.45 * (1 - t);
      scale = 0.32 - 0.08 * t;
      dx = 0;
      dy = 26 + 6 * t;
      rotf = 0;
    }
    return Transform.translate(
      offset: Offset(dx, dy),
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: rotf,
          child: Transform.scale(
            scale: scale.clamp(0.0, 1.2),
            child: _PolaroidCard(seed: delayIndex),
          ),
        ),
      ),
    );
  }
}

class _PolaroidCard extends StatelessWidget {
  final int seed;
  const _PolaroidCard({required this.seed});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 74,
      padding: const EdgeInsets.fromLTRB(5, 5, 5, 15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(3),
        boxShadow: const [
          BoxShadow(color: Color(0x99140804), blurRadius: 16, offset: Offset(0, 10)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: SizedBox(height: 58, child: _DuoPhoto(path: _photo(4 + seed))),
      ),
    );
  }
}

// ── Diapositive 2 : enregistrement vocal → QR imprimé ───────────────────────

class _RecordSlide extends StatefulWidget {
  const _RecordSlide();

  @override
  State<_RecordSlide> createState() => _RecordSlideState();
}

class _RecordSlideState extends State<_RecordSlide>
    with TickerProviderStateMixin {
  late final AnimationController _blink =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))
        ..repeat(reverse: true);
  late final AnimationController _wave =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1050))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _DuoPhoto(path: _photo(8)),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xAD180F0B), Color(0x4D180F0B), Color(0x99180F0B), Color(0xF7180F0B)],
              stops: [0.0, 0.3, 0.6, 0.88],
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, -0.18),
          child: SizedBox(
            width: 300,
            height: 230,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CustomPaint(
                  size: const Size(300, 230),
                  painter: _DashedCurvePainter(
                    from: const Offset(96, 132),
                    control: const Offset(130, 190),
                    to: const Offset(196, 206),
                    color: const Color(0xFFF6DFC4),
                  ),
                ),
                Positioned(left: 2, top: 0, child: _RecordingPhone(blink: _blink, wave: _wave)),
                const Positioned(right: 0, bottom: 2, child: _PrintedPage()),
              ],
            ),
          ),
        ),
        const Align(
          alignment: Alignment.bottomLeft,
          child: _SlideCopy(
            line1: 'Enregistrez-la.',
            line2Plain: 'Le livre ',
            line2Em: 's\'en souvient',
            body: 'Chaque anecdote devient un QR code imprimé sur la page. '
                'Il suffit de le scanner.',
          ),
        ),
      ],
    );
  }
}

class _RecordingPhone extends StatelessWidget {
  final Animation<double> blink;
  final Animation<double> wave;
  const _RecordingPhone({required this.blink, required this.wave});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.12,
      child: Container(
        width: 116,
        decoration: BoxDecoration(
          color: const Color(0xFF191210),
          border: Border.all(color: const Color(0xFF0D0908), width: 4),
          borderRadius: BorderRadius.circular(19),
          boxShadow: const [
            BoxShadow(color: Color(0xF2000000), blurRadius: 24, offset: Offset(0, 16)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 104, width: double.infinity, child: _DuoPhoto(path: _photo(8))),
            Container(
              color: const Color(0xFF191210),
              padding: const EdgeInsets.fromLTRB(9, 9, 9, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AnimatedBuilder(
                        animation: blink,
                        builder: (_, __) => Opacity(
                          opacity: 0.25 + blink.value * 0.75,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                                color: Color(0xFFE0543F), shape: BoxShape.circle),
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      const Text('Enregistrement',
                          style: TextStyle(color: Color(0xFFE9D9CE), fontSize: 9)),
                      const Spacer(),
                      const Text('0:14',
                          style: TextStyle(color: Color(0xFF9E8B80), fontSize: 9)),
                    ],
                  ),
                  const SizedBox(height: 7),
                  SizedBox(
                    height: 22,
                    child: AnimatedBuilder(
                      animation: wave,
                      builder: (_, __) {
                        const heights = [10.0, 17, 21, 13, 19, 8, 16, 20, 12, 18, 7, 15, 19, 11, 17, 9, 20];
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (var i = 0; i < heights.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 2.5),
                                child: Container(
                                  width: 2.5,
                                  height: 4 + (heights[i] - 4) * wave.value,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFD0806A),
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrintedPage extends StatelessWidget {
  const _PrintedPage();

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: 0.07,
      child: Container(
        width: 172,
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFCF7F2),
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [
            BoxShadow(color: Color(0xE6000000), blurRadius: 30, offset: Offset(0, 18)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(height: 66, width: double.infinity, child: _DuoPhoto(path: _photo(9))),
            ),
            const SizedBox(height: 9),
            const Text('Le mariage de Mamie',
                style: TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _Palette.ink)),
            const SizedBox(height: 3),
            Text('AOÛT 1963 · SION',
                style: TextStyle(
                    fontSize: 8, letterSpacing: 1.2, color: const Color(0xFFA8968A))),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.only(top: 9),
              decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Color(0xFFEDE0D6)))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: _Palette.ink.withOpacity(0.88),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: CustomPaint(painter: _QrPainter()),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 9.5, height: 1.4, color: Color(0xFF8A776B)),
                        children: [
                          TextSpan(
                              text: 'Scannez\n',
                              style: TextStyle(
                                  color: _Palette.ink,
                                  fontWeight: FontWeight.w500,
                                  fontFamily: 'Fraunces',
                                  fontSize: 10)),
                          const TextSpan(text: 'pour écouter sa voix raconter ce jour-là.'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Motif façon QR code (purement décoratif, pas un vrai code scannable).
class _QrPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withOpacity(0.92);
    const cell = 4.0;
    final rows = (size.height / cell).floor();
    final cols = (size.width / cell).floor();
    final rnd = math.Random(7);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        if (rnd.nextDouble() > 0.42) {
          canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell - 1, cell - 1), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) => false;
}

/// Trace pointillée courbe entre deux points (utilisée pour relier des
/// éléments — enregistrement→page imprimée, portraits de générations).
class _DashedCurvePainter extends CustomPainter {
  final Offset from;
  final Offset control;
  final Offset to;
  final Color color;
  const _DashedCurvePainter(
      {required this.from, required this.control, required this.to, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(0.8)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    const segments = 40;
    const dashEvery = 3;
    Offset? prev;
    for (var i = 0; i <= segments; i++) {
      final t = i / segments;
      final p = _quad(from, control, to, t);
      if (prev != null && i % dashEvery != 0) {
        canvas.drawLine(prev, p, paint);
      }
      prev = p;
    }
    canvas.drawCircle(to, 3, Paint()..color = color.withOpacity(0.9));
  }

  Offset _quad(Offset a, Offset c, Offset b, double t) {
    final x = math.pow(1 - t, 2) * a.dx + 2 * (1 - t) * t * c.dx + math.pow(t, 2) * b.dx;
    final y = math.pow(1 - t, 2) * a.dy + 2 * (1 - t) * t * c.dy + math.pow(t, 2) * b.dy;
    return Offset(x.toDouble(), y.toDouble());
  }

  @override
  bool shouldRepaint(covariant _DashedCurvePainter oldDelegate) => false;
}

// ── Diapositive 3 : trois générations ────────────────────────────────────────

class _GenerationsSlide extends StatelessWidget {
  const _GenerationsSlide();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_Palette.cream, Color(0xFFF0DFD2)],
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, -0.18),
          child: SizedBox(
            width: 262,
            height: 216,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CustomPaint(
                  size: const Size(262, 216),
                  painter: _DashedCurvePainter(
                    from: const Offset(42, 82),
                    control: const Offset(110, 110),
                    to: const Offset(218, 100),
                    color: const Color(0xFFC08D74),
                  ),
                ),
                const Positioned(left: 2, top: 22, child: _GenPortrait(seed: 6, year: '1952', angle: -0.10)),
                const Positioned(left: 94, top: 0, child: _GenPortrait(seed: 7, year: '1987', angle: 0.05)),
                const Positioned(left: 188, top: 36, child: _GenPortrait(seed: 10, year: '2026', angle: -0.05)),
                Positioned(
                  left: 56,
                  top: 126,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 178),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: _Palette.clay,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(15),
                        topRight: Radius.circular(15),
                        bottomRight: Radius.circular(15),
                        bottomLeft: Radius.circular(3),
                      ),
                      boxShadow: [
                        BoxShadow(
                            color: _Palette.clay.withOpacity(0.35),
                            blurRadius: 26,
                            offset: const Offset(0, 14)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '« Raconte-nous comment vous vous êtes rencontrés. »',
                          style: TextStyle(color: Colors.white, fontSize: 11.5, height: 1.35),
                        ),
                        const SizedBox(height: 4),
                        Text('Invitation envoyée à Mamie',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.72),
                                fontSize: 9,
                                letterSpacing: 0.3)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Align(
          alignment: Alignment.bottomLeft,
          child: _SlideCopy(
            light: true,
            line1: 'Trois générations,',
            line2Plain: '',
            line2Em: 'un seul carnet',
            body: 'Invitez vos proches. Chacun ajoute ses souvenirs depuis son '
                'téléphone.',
          ),
        ),
      ],
    );
  }
}

class _GenPortrait extends StatelessWidget {
  final int seed;
  final String year;
  final double angle;
  const _GenPortrait({required this.seed, required this.year, required this.angle});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        width: 74,
        padding: const EdgeInsets.fromLTRB(5, 5, 5, 17),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(2),
          boxShadow: const [
            BoxShadow(color: Color(0x992A1D14), blurRadius: 22, offset: Offset(0, 12)),
          ],
        ),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(1),
              child: SizedBox(height: 58, width: double.infinity, child: _DuoPhoto(path: _photo(seed))),
            ),
            Positioned(
              bottom: -14,
              left: 0,
              right: 0,
              child: Text(
                year,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: 'Outfit', fontSize: 8, letterSpacing: 1.4, color: Color(0xFFA08E82)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Diapositive 4 : l'étagère des tomes ──────────────────────────────────────

class _ShelfSlide extends StatelessWidget {
  const _ShelfSlide();

  @override
  Widget build(BuildContext context) {
    const tomes = [
      (120.0, '2022', 0),
      (136.0, '2023', 1),
      (126.0, '2024', 2),
      (142.0, '2025', 3),
      (130.0, '2026', 5),
    ];
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, 0.9),
              radius: 1.1,
              colors: [Color(0xFF4C3626), Color(0xFF2A1D14), Color(0xFF150E0A)],
              stops: [0.0, 0.54, 1.0],
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, -0.05),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                Positioned(
                  bottom: 0,
                  left: -26,
                  right: -26,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(colors: [
                        Colors.transparent,
                        _Palette.brass.withOpacity(0.6),
                        Colors.transparent,
                      ]),
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final t in tomes) ...[
                      _Tome(height: t.$1, year: t.$2, seed: t.$3),
                      const SizedBox(width: 9),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        const Align(
          alignment: Alignment.bottomLeft,
          child: _SlideCopy(
            line1: 'Un tome par année,',
            line2Plain: '',
            line2Em: 'toute une vie',
            body: 'Chaque année devient un volume. La collection se lit comme '
                'une histoire.',
          ),
        ),
      ],
    );
  }
}

class _Tome extends StatelessWidget {
  final double height;
  final String year;
  final int seed;
  const _Tome({required this.height, required this.year, required this.seed});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        boxShadow: const [
          BoxShadow(color: Color(0xE6000000), blurRadius: 26, offset: Offset(0, 14)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _DuoPhoto(path: _photo(seed)),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                Colors.black.withOpacity(0.5),
                Colors.black.withOpacity(0.05),
              ]),
            ),
          ),
          Center(
            child: RotatedBox(
              quarterTurns: 1,
              child: Text(
                year,
                style: const TextStyle(
                  fontFamily: 'Fraunces',
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 3,
                  color: Colors.white,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
