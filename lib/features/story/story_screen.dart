import 'dart:math' show min, max, pi;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:printing/printing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/animals.dart';
import '../../core/models/child_model.dart';
import '../../core/models/milestone_model.dart';
import '../../core/models/book_chapter.dart';
import '../../core/models/book_settings.dart';
import '../../core/services/deepseek_service.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/data/growth_data.dart';
import '../../core/utils/date_precision.dart';
import 'book_settings_sheet.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class StoryScreen extends StatefulWidget {
  final String childId;
  const StoryScreen({super.key, required this.childId});

  @override
  State<StoryScreen> createState() => _StoryScreenState();
}

class _StoryScreenState extends State<StoryScreen> {
  ChildModel? _child;
  List<MilestoneModel> _milestones = [];
  List<MilestoneModel> _growthMilestones = [];
  List<BookChapter> _chapters = [];
  BookSettings _settings = const BookSettings();
  DateTime? _generatedAt;
  bool _loading = false;
  bool _isExporting = false;
  int _msgIndex = 0;
  late final PageController _pageController;
  int _currentPage = 0;

  static const _loadingMessages = [
    'Je rassemble les souvenirs ...',
    "J'organise les chapitres ...",
    'Le livre prend forme ...',
    'Les mots s\'assemblent ...',
    'Presque prêt ...',
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _pageController.addListener(() {
      final p = _pageController.page?.round() ?? 0;
      if (p != _currentPage && mounted) setState(() => _currentPage = p);
    });
    _loadData();
    _loadSavedBook();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  Future<void> _loadSavedBook() async {
    final doc = await FirebaseFirestore.instance
        .collection('books')
        .doc(widget.childId)
        .get();
    if (!mounted || !doc.exists) return;
    final data = doc.data()!;
    final rawChapters = data['chapters'] as List<dynamic>?;
    if (rawChapters == null || rawChapters.isEmpty) return;
    final chapters = rawChapters
        .map((c) => BookChapter(
              title: (c as Map<String, dynamic>)['title'] as String? ?? '',
              body: c['body'] as String? ?? '',
            ))
        .toList();
    final settingsData = data['settings'] as Map<String, dynamic>?;
    setState(() {
      _chapters = chapters;
      if (settingsData != null) _settings = BookSettings.fromMap(settingsData);
      _generatedAt = (data['generatedAt'] as Timestamp?)?.toDate();
    });
  }

  Future<void> _saveBook(List<BookChapter> chapters) async {
    await FirebaseFirestore.instance
        .collection('books')
        .doc(widget.childId)
        .set({
      'chapters':
          chapters.map((c) => {'title': c.title, 'body': c.body}).toList(),
      'generatedAt': Timestamp.now(),
      'settings': _settings.toMap(),
    });
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    final results = await Future.wait([
      FirebaseFirestore.instance.collection('children').doc(widget.childId).get(),
      FirebaseFirestore.instance
          .collection('milestones')
          .where('childId', isEqualTo: widget.childId)
          .get(),
    ]);
    if (!mounted) return;
    final all = (results[1] as QuerySnapshot)
        .docs
        .map((d) => MilestoneModel.fromFirestore(d))
        .toList();
    setState(() {
      _child = ChildModel.fromFirestore(results[0] as DocumentSnapshot);
      _milestones = all.where((m) => m.type != 'taille_poids').toList();
      _growthMilestones = all
          .where((m) =>
              m.type == 'taille_poids' &&
              (m.heightCm != null || m.weightKg != null))
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
    });
  }

  // ── Generation ─────────────────────────────────────────────────────────────

  Future<void> _generate() async {
    if (_child == null) return;
    setState(() {
      _loading = true;
      _chapters = [];
      _msgIndex = 0;
    });

    final ticker = Stream.periodic(const Duration(seconds: 3)).listen((_) {
      if (mounted && _loading) {
        setState(() => _msgIndex = (_msgIndex + 1) % _loadingMessages.length);
      }
    });

    final text = await DeepSeekService(apiKey: AppConfig.deepseekApiKey)
        .generateMemoryBook(
      childName: _child!.firstName,
      gender: _child!.gender,
      birthDate: _child!.birthDate,
      milestones: [..._milestones, ..._growthMilestones],
      settings: _settings,
    );

    ticker.cancel();
    if (!mounted) return;

    final chapters = _parseChapters(text ?? 'Une erreur est survenue. Réessaie.');
    final now = DateTime.now();
    setState(() {
      _chapters = chapters;
      _generatedAt = now;
      _loading = false;
    });

    // Save to Firestore
    if (chapters.isNotEmpty) _saveBook(chapters);

    if (chapters.isNotEmpty && _pageController.hasClients) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) {
        _pageController.animateToPage(
          1,
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BookSettingsSheet(
        initial: _settings,
        onApply: (newSettings, regenerate) {
          setState(() => _settings = newSettings);
          if (regenerate) _generate();
        },
      ),
    );
  }

  Future<void> _exportPdf() async {
    if (_child == null || _chapters.isEmpty) return;
    setState(() => _isExporting = true);
    try {
      final animal = getAnimalById(_child!.animalId);
      final coverColor = Color(
          int.parse('FF${_child!.coverColor.replaceAll('#', '')}', radix: 16));
      final bytes = await BookPdfService.generate(
        child: _child!,
        animalId: animal.id,
        coverColor: coverColor,
        chapters: _chapters,
        growthMilestones: _growthMilestones,
      );
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'livre_${_child!.firstName.toLowerCase()}.pdf',
      );
    } catch (e, st) {
      debugPrint('PDF export error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur export PDF : $e'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  List<BookChapter> _parseChapters(String text) {
    final result = <BookChapter>[];
    for (final section in text.split('\n\n').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
      final lines = section.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      if (lines.isEmpty) continue;
      String title = '';
      var bodyLines = lines;
      final first = lines[0];
      if (first.startsWith('**') && first.length > 4) {
        title = first.replaceAll('**', '').trim();
        bodyLines = lines.sublist(1);
      }
      final body = bodyLines.join(' ').trim();
      if (body.isNotEmpty) result.add(BookChapter(title: title, body: body));
    }
    return result;
  }

  // ── Page helpers ───────────────────────────────────────────────────────────

  bool get _hasGrowthPage => _growthMilestones.length >= 2;

  int get _totalPages {
    int n = 1; // cover
    n += _chapters.isEmpty ? 1 : _chapters.length;
    if (_hasGrowthPage) n++;
    return n;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_child == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final animal = getAnimalById(_child!.animalId);
    final coverColor = Color(
        int.parse('FF${_child!.coverColor.replaceAll('#', '')}', radix: 16));
    final svgPath = 'assets/images/animals/${animal.id}.svg';
    final pages = _buildAllPages(coverColor, svgPath);

    return Scaffold(
      backgroundColor: const Color(0xFF1C1510),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1510),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white70),
          onPressed: () => context.go('/child/${widget.childId}'),
        ),
        title: Text(
          'Le livre de ${_child!.firstName}',
          style: const TextStyle(
            fontFamily: 'PlayfairDisplay',
            color: Colors.white,
            fontSize: 18,
          ),
        ),
        actions: const [],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: PageView.builder(
                controller: _pageController,
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemBuilder: (context, index) => _AnimatedPage(
                  controller: _pageController,
                  index: index,
                  child: pages[index],
                ),
              ),
            ),
          ),
          // Action strip (export / settings / regenerate)
          if (_chapters.isNotEmpty)
            _BookActionStrip(
              accentColor: coverColor,
              isExporting: _isExporting,
              generatedAt: _generatedAt,
              onExport: _exportPdf,
              onSettings: _showSettings,
              onRegenerate: _loading ? null : _generate,
            ),
          _BookNavBar(
            current: _currentPage,
            total: pages.length,
            accentColor: coverColor,
            onPrev: _currentPage > 0
                ? () => _pageController.previousPage(
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeInOut)
                : null,
            onNext: _currentPage < pages.length - 1
                ? () => _pageController.nextPage(
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeInOut)
                : null,
          ),
        ],
      ),
    );
  }

  // ── Pages list ─────────────────────────────────────────────────────────────

  List<Widget> _buildAllPages(Color coverColor, String svgPath) {
    final pages = <Widget>[_pageCover(coverColor, svgPath)];

    if (_chapters.isEmpty) {
      pages.add(_pageGenerate(coverColor, svgPath));
    } else {
      for (int i = 0; i < _chapters.length; i++) {
        pages.add(_pageChapter(_chapters[i], chapterIdx: i, coverColor: coverColor));
      }
    }

    if (_hasGrowthPage) {
      pages.add(_pageGrowth(coverColor));
    }

    return pages;
  }

  // ── Page: Cover ────────────────────────────────────────────────────────────

  Widget _pageCover(Color coverColor, String svgPath) {
    final birth = _child!.birthDate;
    final nowYear = DateTime.now().year;
    final range = birth.year == nowYear ? '${birth.year}' : '${birth.year} — $nowYear';

    return _BookPage(
      color: coverColor,
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _DotPatternPainter())),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SvgPicture.asset(svgPath, width: 160, height: 160),
                const SizedBox(height: 28),
                Text(
                  'Le livre de',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(0.8),
                    fontStyle: FontStyle.italic,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _child!.firstName,
                  style: const TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [Shadow(color: Colors.black38, blurRadius: 14)],
                  ),
                ),
                const SizedBox(height: 18),
                Container(width: 52, height: 1.5, color: Colors.white.withOpacity(0.45)),
                const SizedBox(height: 18),
                Text(
                  'LIVRE DE SOUVENIRS',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withOpacity(0.75),
                    letterSpacing: 3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  range,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withOpacity(0.5),
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Page: Generate / Loading ───────────────────────────────────────────────

  Widget _pageGenerate(Color coverColor, String svgPath) {
    if (_loading) {
      return _BookPage(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(svgPath, width: 88, height: 88),
            const SizedBox(height: 28),
            const CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.sage),
            const SizedBox(height: 20),
            Text(
              _loadingMessages[_msgIndex],
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 17,
                color: AppColors.textMedium,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      );
    }

    final count = _milestones.length;
    return _BookPage(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(svgPath, width: 80, height: 80),
            const SizedBox(height: 24),
            const Text(
              'Aperçu du livre',
              style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              count > 0
                  ? 'L\'IA va organiser $count souvenir${count > 1 ? 's' : ''}\nen chapitres chronologiques.'
                  : 'Ajoute des souvenirs pour créer le livre.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textMedium,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 32),
            if (count > 0)
              GestureDetector(
                onTap: _generate,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 15, horizontal: 30),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        coverColor,
                        Color.lerp(coverColor, Colors.brown, 0.25)!,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(50),
                    boxShadow: [
                      BoxShadow(
                        color: coverColor.withOpacity(0.45),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_stories, color: Colors.white, size: 18),
                      SizedBox(width: 10),
                      Text(
                        'Créer l\'aperçu',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Page: Chapter ──────────────────────────────────────────────────────────

  static const _roman = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII'];

  Widget _pageChapter(
    BookChapter chapter, {
    required int chapterIdx,
    required Color coverColor,
  }) {
    final pageNum = chapterIdx + 2;

    return _BookPage(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 32, 28, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              'Chapitre ${_roman[chapterIdx % _roman.length]}',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 3,
                color: coverColor.withOpacity(0.6),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            if (chapter.title.isNotEmpty)
              Text(
                chapter.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'PlayfairDisplay',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark,
                ),
              ),
            const SizedBox(height: 14),
            // Ornamental divider
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(width: 28, height: 1, color: coverColor.withOpacity(0.3)),
                const SizedBox(width: 6),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: coverColor.withOpacity(0.4),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Container(width: 28, height: 1, color: coverColor.withOpacity(0.3)),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  chapter.body,
                  textAlign: TextAlign.justify,
                  style: const TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontSize: 15,
                    color: AppColors.textDark,
                    height: 1.95,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$pageNum / $_totalPages',
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textMedium.withOpacity(0.35),
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Page: Growth ───────────────────────────────────────────────────────────

  Widget _pageGrowth(Color coverColor) {
    return _BookPage(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 3,
                  height: 22,
                  decoration: BoxDecoration(
                    color: coverColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Évolution croissance',
                  style: TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsets.only(left: 13),
              child: Text(
                'OMS 2006 — P3, P50, P97',
                style: TextStyle(fontSize: 9, color: Colors.grey.shade400),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: _GrowthPageContent(
                child: _child!,
                growthMilestones: _growthMilestones,
                coverColor: coverColor,
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$_totalPages / $_totalPages',
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textMedium.withOpacity(0.35),
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 3D page flip animation ────────────────────────────────────────────────────

class _AnimatedPage extends StatelessWidget {
  final PageController controller;
  final int index;
  final Widget child;

  const _AnimatedPage({
    required this.controller,
    required this.index,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (ctx, c) {
        double offset = 0;
        if (controller.hasClients && controller.position.haveDimensions) {
          offset = (controller.page! - index).clamp(-1.0, 1.0);
        }
        final isLeaving = offset > 0;
        final angle = offset * (pi / 5.5);
        return Transform(
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateY(angle),
          alignment: isLeaving ? Alignment.centerRight : Alignment.centerLeft,
          child: c,
        );
      },
      child: child,
    );
  }
}

// ── Book page wrapper (paper + shadow) ───────────────────────────────────────

class _BookPage extends StatelessWidget {
  final Widget child;
  final Color? color;

  const _BookPage({required this.child, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color ?? const Color(0xFFFAF6EE),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.55),
            blurRadius: 28,
            offset: const Offset(6, 8),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 6,
            offset: const Offset(-3, 0),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: child,
      ),
    );
  }
}

// ── Bottom navigation bar ─────────────────────────────────────────────────────

class _BookNavBar extends StatelessWidget {
  final int current;
  final int total;
  final Color accentColor;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const _BookNavBar({
    required this.current,
    required this.total,
    required this.accentColor,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1C1510),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 28),
      child: Row(
        children: [
          IconButton(
            onPressed: onPrev,
            icon: Icon(
              Icons.chevron_left,
              color: onPrev != null ? Colors.white70 : Colors.white24,
              size: 30,
            ),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(total, (i) {
                final active = i == current;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 22 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: active ? accentColor : Colors.white24,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: Icon(
              Icons.chevron_right,
              color: onNext != null ? Colors.white70 : Colors.white24,
              size: 30,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Action strip (export / settings / regenerate) ────────────────────────────

class _BookActionStrip extends StatelessWidget {
  final Color accentColor;
  final bool isExporting;
  final DateTime? generatedAt;
  final VoidCallback onExport;
  final VoidCallback onSettings;
  final VoidCallback? onRegenerate;

  const _BookActionStrip({
    required this.accentColor,
    required this.isExporting,
    required this.generatedAt,
    required this.onExport,
    required this.onSettings,
    required this.onRegenerate,
  });

  String _fmtDate(DateTime d) {
    const months = [
      'jan', 'fév', 'mar', 'avr', 'mai', 'jun',
      'jul', 'aoû', 'sep', 'oct', 'nov', 'déc'
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF251E16),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          // Settings
          _StripBtn(
            icon: Icons.tune,
            label: 'Paramètres',
            color: Colors.white54,
            onTap: onSettings,
          ),
          const Spacer(),

          // Export PDF — prominent center button
          GestureDetector(
            onTap: isExporting ? null : onExport,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: isExporting ? Colors.white12 : accentColor,
                borderRadius: BorderRadius.circular(20),
              ),
              child: isExporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.picture_as_pdf_outlined,
                            color: Colors.white, size: 16),
                        SizedBox(width: 6),
                        Text(
                          'Exporter PDF',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
            ),
          ),

          const Spacer(),

          // Regenerate
          _StripBtn(
            icon: Icons.refresh,
            label: 'Régénérer',
            color: onRegenerate != null ? Colors.white54 : Colors.white24,
            onTap: onRegenerate,
            sublabel: generatedAt != null ? _fmtDate(generatedAt!) : null,
          ),
        ],
      ),
    );
  }
}

class _StripBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? sublabel;
  final Color color;
  final VoidCallback? onTap;

  const _StripBtn({
    required this.icon,
    required this.label,
    required this.color,
    this.sublabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.w500)),
          if (sublabel != null)
            Text(sublabel!,
                style: TextStyle(
                    color: color.withOpacity(0.6), fontSize: 8)),
        ],
      ),
    );
  }
}

// ── Dot pattern painter (cover deco) ─────────────────────────────────────────

class _DotPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.07)
      ..style = PaintingStyle.fill;
    for (double x = 0; x < size.width; x += 24) {
      for (double y = 0; y < size.height; y += 24) {
        canvas.drawCircle(Offset(x, y), 2.5, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

// ── Growth page content ───────────────────────────────────────────────────────

class _GrowthPageContent extends StatefulWidget {
  final ChildModel child;
  final List<MilestoneModel> growthMilestones;
  final Color coverColor;

  const _GrowthPageContent({
    required this.child,
    required this.growthMilestones,
    required this.coverColor,
  });

  @override
  State<_GrowthPageContent> createState() => _GrowthPageContentState();
}

class _GrowthPageContentState extends State<_GrowthPageContent> {
  bool _showWeight = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Taille / Poids toggle
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              _chip('📏 Taille', !_showWeight, () => setState(() => _showWeight = false)),
              _chip('⚖️ Poids', _showWeight, () => setState(() => _showWeight = true)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // Chart
        Expanded(
          flex: 5,
          child: _GrowthLineChart(
            child: widget.child,
            milestones: widget.growthMilestones,
            showWeight: _showWeight,
            coverColor: widget.coverColor,
          ),
        ),
        const SizedBox(height: 10),
        // Measurements list
        Expanded(
          flex: 3,
          child: _MeasurementsList(
            milestones: widget.growthMilestones,
            showWeight: _showWeight,
            coverColor: widget.coverColor,
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: active ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: active
                  ? [BoxShadow(color: Colors.black.withOpacity(0.07), blurRadius: 4)]
                  : null,
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                color: active ? AppColors.sage : Colors.grey.shade400,
              ),
            ),
          ),
        ),
      );
}

// ── Growth line chart (WHO reference + child data) ────────────────────────────

class _GrowthLineChart extends StatelessWidget {
  final ChildModel child;
  final List<MilestoneModel> milestones;
  final bool showWeight;
  final Color coverColor;

  const _GrowthLineChart({
    required this.child,
    required this.milestones,
    required this.showWeight,
    required this.coverColor,
  });

  @override
  Widget build(BuildContext context) {
    final refData = getGrowthData(gender: child.gender, isWeight: showWeight);
    final p3 = refData.map((p) => FlSpot(p.month.toDouble(), p.p3)).toList();
    final p50 = refData.map((p) => FlSpot(p.month.toDouble(), p.p50)).toList();
    final p97 = refData.map((p) => FlSpot(p.month.toDouble(), p.p97)).toList();

    final childSpots = milestones
        .where((m) => showWeight ? m.weightKg != null : m.heightCm != null)
        .map((m) {
          final ageM = ((m.date.year - child.birthDate.year) * 12 +
                  m.date.month -
                  child.birthDate.month)
              .toDouble()
              .clamp(0.0, double.infinity);
          return FlSpot(ageM, showWeight ? m.weightKg! : m.heightCm!);
        })
        .toList();

    if (childSpots.isEmpty) {
      return Center(
        child: Text(
          showWeight ? 'Aucun poids enregistré' : 'Aucune taille enregistrée',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
        ),
      );
    }

    final unit = showWeight ? 'kg' : 'cm';
    final maxX =
        (childSpots.map((s) => s.x).reduce(max) * 1.08).clamp(12.0, double.infinity);

    final allYs = [
      ...p3.map((s) => s.y),
      ...p97.map((s) => s.y),
      ...childSpots.map((s) => s.y),
    ];
    final rawMin = allYs.reduce(min);
    final rawMax = allYs.reduce(max);
    final pad = (rawMax - rawMin) * 0.1;

    return LineChart(
      LineChartData(
        lineBarsData: [
          _ref(p3, Colors.grey.shade200),
          _ref(p50, AppColors.sage.withOpacity(0.28)),
          _ref(p97, Colors.grey.shade200),
          LineChartBarData(
            spots: childSpots,
            isCurved: childSpots.length > 1,
            color: coverColor,
            barWidth: 2.5,
            dotData: FlDotData(
              show: true,
              getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
                radius: 5,
                color: coverColor,
                strokeWidth: 2,
                strokeColor: Colors.white,
              ),
            ),
          ),
        ],
        minX: 0,
        maxX: maxX,
        minY: (rawMin - pad).clamp(0, rawMin),
        maxY: rawMax + pad,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: Colors.grey.shade100, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, _) => Text(
                showWeight ? v.toStringAsFixed(1) : '${v.toInt()}',
                style: TextStyle(fontSize: 8, color: Colors.grey.shade400),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) => Text(
                '${v.toInt()}m',
                style: TextStyle(fontSize: 8, color: Colors.grey.shade400),
              ),
            ),
          ),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((s) {
              if (s.barIndex != 3) {
                return LineTooltipItem('', const TextStyle(fontSize: 0));
              }
              return LineTooltipItem(
                '${s.x.toInt()}m — ${s.y.toStringAsFixed(1)} $unit',
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  LineChartBarData _ref(List<FlSpot> spots, Color color) => LineChartBarData(
        spots: spots,
        isCurved: true,
        color: color,
        barWidth: 1.5,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      );
}

// ── Measurements list (bottom of growth page) ────────────────────────────────

class _MeasurementsList extends StatelessWidget {
  final List<MilestoneModel> milestones;
  final bool showWeight;
  final Color coverColor;

  const _MeasurementsList({
    required this.milestones,
    required this.showWeight,
    required this.coverColor,
  });

  @override
  Widget build(BuildContext context) {
    final items = milestones.reversed
        .where((m) => showWeight ? m.weightKg != null : m.heightCm != null)
        .take(5)
        .toList();

    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: Color(0xFFEFEBE3)),
      itemBuilder: (_, i) {
        final m = items[i];
        final date = m.dateLabel ??
            formatDateWithPrecision(
                m.date, datePrecisionFromString(m.datePrecision));
        final value = showWeight
            ? '${m.weightKg!.toStringAsFixed(1)} kg'
            : '${m.heightCm!.toStringAsFixed(0)} cm';
        final isLatest = i == 0;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: isLatest ? coverColor : Colors.grey.shade300,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                date,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isLatest ? coverColor : AppColors.textDark,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
