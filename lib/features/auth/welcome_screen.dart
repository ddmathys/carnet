import 'dart:async';
import 'package:flutter/material.dart';
import 'welcome_slides.dart';

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
      backgroundColor: WelcomePalette.espresso,
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
                    BookSlide(),
                    RecordSlide(),
                    GenerationsSlide(),
                    ShelfSlide(),
                  ],
                ),
                Positioned(
                  top: 26,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(child: BrandMark(light: isLight)),
                ),
                Positioned(
                  left: 26,
                  bottom: 20,
                  child: StitchIndicator(
                      index: _index, light: isLight, onTap: _goTo),
                ),
              ],
            ),
          ),
          const BottomSheetCta(),
        ],
      ),
    );
  }
}

