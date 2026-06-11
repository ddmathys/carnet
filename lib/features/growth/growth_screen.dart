import 'dart:math' show min, max;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/child_model.dart';
import '../../core/models/milestone_model.dart';
import '../../core/data/growth_data.dart';
import '../../core/utils/date_precision.dart';
import '../../core/services/deepseek_service.dart';

class GrowthScreen extends StatefulWidget {
  final String childId;
  const GrowthScreen({super.key, required this.childId});

  @override
  State<GrowthScreen> createState() => _GrowthScreenState();
}

class _GrowthScreenState extends State<GrowthScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance
          .collection('children')
          .doc(widget.childId)
          .get(),
      builder: (context, childSnap) {
        if (!childSnap.hasData) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final child = ChildModel.fromFirestore(childSnap.data!);

        return Scaffold(
          backgroundColor: AppColors.cream,
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => context.push('/child/${widget.childId}/add-milestone'),
            backgroundColor: AppColors.sage,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add),
            label: const Text('Nouveau souvenir'),
          ),
          appBar: AppBar(
            backgroundColor: AppColors.cream,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.pop(),
            ),
            title: Text('Croissance de ${child.firstName}'),
            bottom: TabBar(
              controller: _tabController,
              labelColor: AppColors.sage,
              unselectedLabelColor: AppColors.softGray,
              indicatorColor: AppColors.sage,
              tabs: const [
                Tab(icon: Icon(Icons.show_chart), text: 'Courbes'),
                Tab(icon: Icon(Icons.straighten), text: 'Toise'),
              ],
            ),
          ),
          body: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('milestones')
                .where('childId', isEqualTo: widget.childId)
                .where('type', isEqualTo: 'taille_poids')
                .snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final milestones = snap.data!.docs
                  .map((d) => MilestoneModel.fromFirestore(d))
                  .where((m) => m.heightCm != null || m.weightKg != null)
                  .toList()
                ..sort((a, b) => a.date.compareTo(b.date));

              if (milestones.isEmpty) {
                return _EmptyState(child: child, childId: widget.childId);
              }

              return TabBarView(
                controller: _tabController,
                children: [
                  _CurvesTab(child: child, milestones: milestones),
                  _ToiseTab(
                    child: child,
                    milestones: milestones,
                    childId: widget.childId,
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

// ─── Curves Tab ───────────────────────────────────────────────────────────────

class _CurvesTab extends StatefulWidget {
  final ChildModel child;
  final List<MilestoneModel> milestones;
  const _CurvesTab({required this.child, required this.milestones});

  @override
  State<_CurvesTab> createState() => _CurvesTabState();
}

class _CurvesTabState extends State<_CurvesTab> {
  bool _showWeight = false;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ToggleBar(
            showWeight: _showWeight,
            onChanged: (v) => setState(() => _showWeight = v),
          ),
          const SizedBox(height: 20),
          _MultiPointChart(
            child: widget.child,
            milestones: widget.milestones,
            showWeight: _showWeight,
          ),
          const SizedBox(height: 24),
          _MeasurementList(
            milestones: widget.milestones,
            showWeight: _showWeight,
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

class _ToggleBar extends StatelessWidget {
  final bool showWeight;
  final ValueChanged<bool> onChanged;
  const _ToggleBar({required this.showWeight, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _chip('📏  Taille', !showWeight, () => onChanged(false)),
          _chip('⚖️  Poids', showWeight, () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: active ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.08),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      )
                    ]
                  : null,
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                color: active ? AppColors.sage : Colors.grey.shade500,
              ),
            ),
          ),
        ),
      );
}

class _MultiPointChart extends StatelessWidget {
  final ChildModel child;
  final List<MilestoneModel> milestones;
  final bool showWeight;

  const _MultiPointChart({
    required this.child,
    required this.milestones,
    required this.showWeight,
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

    final unit = showWeight ? 'kg' : 'cm';

    // X axis: adapt to actual child age, minimum 12 months shown
    final maxChildAge = childSpots.isEmpty
        ? 24.0
        : childSpots.map((s) => s.x).reduce(max);
    final maxX = (maxChildAge * 1.05).ceilToDouble().clamp(12.0, double.infinity);

    // Y axis: child values + WHO reference (capped at their max month)
    final refYs = [...p3.map((s) => s.y), ...p97.map((s) => s.y)];
    final childYs = childSpots.map((s) => s.y);
    final allYs = [...refYs, ...childYs];
    final rawMinY = allYs.isEmpty ? 0.0 : allYs.reduce(min);
    final rawMaxY = allYs.isEmpty ? 100.0 : allYs.reduce(max);
    final yPad = (rawMaxY - rawMinY) * 0.08;
    final dynMinY = (rawMinY - yPad).clamp(0.0, rawMinY);
    final dynMaxY = rawMaxY + yPad;
    final yRange = dynMaxY - dynMinY;
    final yInterval = yRange <= 10
        ? 1.0
        : yRange <= 20
            ? 2.0
            : yRange <= 50
                ? 5.0
                : 10.0;
    final xInterval = maxX <= 12
        ? 2.0
        : maxX <= 24
            ? 3.0
            : maxX <= 48
                ? 6.0
                : 12.0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                showWeight
                    ? 'Poids (kg) — 0 à ${maxX.toInt()} mois'
                    : 'Taille (cm) — 0 à ${maxX.toInt()} mois',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: AppColors.textDark,
                ),
              ),
              const Spacer(),
              Text(
                child.gender == 'boy' ? '👦' : '👧',
                style: const TextStyle(fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'OMS 2006 — P3, P50, P97',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 220,
            child: LineChart(
              LineChartData(
                lineBarsData: [
                  _ref(p3, Colors.grey.shade200),
                  _ref(p50, AppColors.sage.withOpacity(0.35)),
                  _ref(p97, Colors.grey.shade200),
                  if (childSpots.isNotEmpty)
                    LineChartBarData(
                      spots: childSpots,
                      isCurved: childSpots.length > 1,
                      color: AppColors.sage,
                      barWidth: 2.5,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (_, __, ___, ____) =>
                            FlDotCirclePainter(
                          radius: 6,
                          color: AppColors.sage,
                          strokeWidth: 2,
                          strokeColor: Colors.white,
                        ),
                      ),
                    ),
                ],
                minX: 0,
                maxX: maxX,
                minY: dynMinY,
                maxY: dynMaxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: yInterval,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: Colors.grey.shade100, strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 42,
                      interval: yInterval,
                      getTitlesWidget: (v, _) => Text(
                        showWeight
                            ? v.toStringAsFixed(1)
                            : '${v.toInt()}$unit',
                        style: TextStyle(
                            fontSize: 9, color: Colors.grey.shade400),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: xInterval,
                      getTitlesWidget: (v, _) => Text(
                        '${v.toInt()}m',
                        style: TextStyle(
                            fontSize: 9, color: Colors.grey.shade400),
                      ),
                    ),
                  ),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                ),
                lineTouchData: LineTouchData(
                  enabled: childSpots.isNotEmpty,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (spots) => spots.map((s) {
                      if (s.barIndex != 3) {
                        return LineTooltipItem('', const TextStyle(fontSize: 0));
                      }
                      return LineTooltipItem(
                        '${s.x.toInt()}m — ${s.y.toStringAsFixed(1)}$unit',
                        const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ],
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

class _MeasurementList extends StatelessWidget {
  final List<MilestoneModel> milestones;
  final bool showWeight;

  const _MeasurementList({required this.milestones, required this.showWeight});

  String _label(MilestoneModel m) =>
      m.dateLabel ??
      formatDateWithPrecision(
          m.date, datePrecisionFromString(m.datePrecision));

  @override
  Widget build(BuildContext context) {
    final items = milestones
        .where((m) => showWeight ? m.weightKg != null : m.heightCm != null)
        .toList()
        .reversed
        .toList();

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            showWeight ? 'Aucun poids enregistré' : 'Aucune taille enregistrée',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Historique',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            color: AppColors.textDark,
          ),
        ),
        const SizedBox(height: 12),
        ...items.asMap().entries.map((e) {
          final i = e.key;
          final m = e.value;
          final isLatest = i == 0;
          final value = showWeight
              ? '${m.weightKg!.toStringAsFixed(1)} kg'
              : '${m.heightCm!.toStringAsFixed(0)} cm';

          String? gain;
          if (i < items.length - 1) {
            final prev = items[i + 1];
            if (showWeight && prev.weightKg != null) {
              final diff = m.weightKg! - prev.weightKg!;
              if (diff > 0) gain = '+${diff.toStringAsFixed(1)} kg';
            } else if (!showWeight && prev.heightCm != null) {
              final diff = m.heightCm! - prev.heightCm!;
              if (diff > 0) gain = '+${diff.toStringAsFixed(0)} cm';
            }
          }

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isLatest ? AppColors.sage.withOpacity(0.08) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isLatest
                    ? AppColors.sage.withOpacity(0.3)
                    : Colors.grey.shade100,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isLatest ? AppColors.sage : Colors.grey.shade100,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    showWeight ? Icons.monitor_weight_outlined : Icons.height,
                    color: isLatest ? Colors.white : Colors.grey.shade400,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 20,
                          color: isLatest ? AppColors.sage : AppColors.textDark,
                        ),
                      ),
                      Text(
                        _label(m),
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                ),
                if (gain != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      gain,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.green.shade600,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

// ─── Toise Tab ────────────────────────────────────────────────────────────────

class _ToiseTab extends StatelessWidget {
  final ChildModel child;
  final List<MilestoneModel> milestones;
  final String childId;

  const _ToiseTab({
    required this.child,
    required this.milestones,
    required this.childId,
  });

  @override
  Widget build(BuildContext context) {
    final hMeasurements = milestones
        .where((m) => m.heightCm != null)
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final latestHeight =
        hMeasurements.isNotEmpty ? hMeasurements.last.heightCm! : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(
        children: [
          // Header card
          if (latestHeight != null)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.sage.withOpacity(0.15),
                    AppColors.sage.withOpacity(0.03),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.sage.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${latestHeight.toStringAsFixed(0)} cm',
                        style: const TextStyle(
                          fontSize: 52,
                          fontWeight: FontWeight.w800,
                          color: AppColors.sage,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Dernière mesure de ${child.firstName}',
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                  const Spacer(),
                  SvgPicture.asset(
                    'assets/images/animals/${child.animalId}.svg',
                    width: 80,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          // Toise visuelle
          if (hMeasurements.isNotEmpty)
            _ToiseVisual(child: child, measurements: hMeasurements)
          else
            _NoHeightHint(childName: child.firstName),
          const SizedBox(height: 20),
          // Bouton photo
          _PhotoButton(
            child: child,
            childId: childId,
            milestones: milestones,
          ),
        ],
      ),
    );
  }
}

class _NoHeightHint extends StatelessWidget {
  final String childName;
  const _NoHeightHint({required this.childName});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Column(
        children: [
          const Text('📏', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 12),
          Text(
            'Aucune taille enregistrée',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Ajoute une première mesure via le bouton photo ci-dessous',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }
}

// ─── Toise Visuelle ────────────────────────────────────────────────────────────

class _ToiseVisual extends StatelessWidget {
  final ChildModel child;
  final List<MilestoneModel> measurements;

  const _ToiseVisual({required this.child, required this.measurements});

  @override
  Widget build(BuildContext context) {
    final latestH = measurements.last.heightCm!;
    const double minDisplayH = 40.0;
    final double maxDisplayH = (latestH + 15).clamp(90.0, 160.0);
    const double canvasH = 600.0;
    final double scale = canvasH / (maxDisplayH - minDisplayH);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              const Icon(Icons.pinch_outlined, size: 14, color: AppColors.softGray),
              const SizedBox(width: 4),
              Text(
                'Pince pour zoomer',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFAF6EE),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE8DECC)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              height: canvasH,
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.0,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.maxWidth;
                    final animalAreaW = w * 0.38;
                    final animalH = (animalAreaW * 225 / 200).clamp(0.0, canvasH * 0.78);

                    return Stack(
                      children: [
                        CustomPaint(
                          size: Size(w, canvasH),
                          painter: _ToisePainter(
                            measurements: measurements,
                            childName: child.firstName,
                            minH: minDisplayH,
                            maxH: maxDisplayH,
                            scale: scale,
                            animalAreaW: animalAreaW,
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: SvgPicture.asset(
                            'assets/images/animals/${child.animalId}.svg',
                            width: animalAreaW,
                            height: animalH,
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomCenter,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ToisePainter extends CustomPainter {
  final List<MilestoneModel> measurements;
  final String childName;
  final double minH;
  final double maxH;
  final double scale;
  final double animalAreaW;

  _ToisePainter({
    required this.measurements,
    required this.childName,
    required this.minH,
    required this.maxH,
    required this.scale,
    required this.animalAreaW,
  });

  double _y(double h) => (maxH - h) * scale;

  static const _rulerStripW = 28.0;
  static const _palette = [
    Color(0xFF7A9E7E),
    Color(0xFF7A9EC8),
    Color(0xFFD4956A),
    Color(0xFFB07AB8),
    Color(0xFFD47A7A),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final lineEndX = size.width - animalAreaW - 8;
    final labelStartX = _rulerStripW + 8.0;

    // Ruler strip background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, _rulerStripW, size.height),
      Paint()..color = const Color(0xFFEDE3D0),
    );
    // Ruler right border
    canvas.drawLine(
      Offset(_rulerStripW, 0),
      Offset(_rulerStripW, size.height),
      Paint()
        ..color = const Color(0xFFBFAA95)
        ..strokeWidth = 1.5,
    );

    // Tick marks on ruler
    for (double h = minH; h <= maxH; h += 5) {
      final y = _y(h);
      final isMajor = h % 10 == 0;
      canvas.drawLine(
        Offset(isMajor ? 0 : 8, y),
        Offset(_rulerStripW, y),
        Paint()
          ..color = isMajor ? const Color(0xFF8B7355) : const Color(0xFFBFAA95)
          ..strokeWidth = isMajor ? 1.5 : 1.0,
      );
      if (isMajor) {
        _text(canvas, '${h.toInt()}',
            Offset(1, y - 7),
            fontSize: 10.0,
            color: const Color(0xFF8B7355),
            bold: true);
      }
    }

    // Measurement lines + labels
    for (int i = 0; i < measurements.length; i++) {
      final m = measurements[i];
      final h = m.heightCm!;
      final y = _y(h);
      final isLatest = i == measurements.length - 1;
      final color = _palette[i % _palette.length];

      // Horizontal line
      if (isLatest) {
        canvas.drawLine(
          Offset(_rulerStripW, y),
          Offset(lineEndX, y),
          Paint()
            ..color = color
            ..strokeWidth = 2.5,
        );
        _drawArrow(canvas, Offset(lineEndX, y), color);
      } else {
        _dashed(
          canvas,
          Offset(_rulerStripW, y),
          Offset(lineEndX - 10, y),
          Paint()
            ..color = color.withOpacity(0.55)
            ..strokeWidth = 1.5,
        );
      }

      // Dot on ruler
      canvas.drawCircle(
          Offset(_rulerStripW, y), isLatest ? 7.0 : 5.5, Paint()..color = color);
      canvas.drawCircle(
          Offset(_rulerStripW, y), isLatest ? 3.2 : 2.4, Paint()..color = Colors.white);

      // Labels
      final valStr = '${h.toStringAsFixed(0)} cm';
      final dateStr = m.dateLabel ?? _fmt(m.date);
      _text(canvas, valStr, Offset(labelStartX, y - 18),
          fontSize: isLatest ? 17.0 : 14.0, color: color, bold: true);
      _text(canvas, isLatest ? '$dateStr — $childName' : dateStr,
          Offset(labelStartX, y + 2),
          fontSize: 12.0,
          color: isLatest
              ? color.withOpacity(0.8)
              : const Color(0xFF9E9E9E));
    }
  }

  void _drawArrow(Canvas canvas, Offset tip, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(tip.dx - 8, tip.dy - 5)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - 8, tip.dy + 5);
    canvas.drawPath(path, paint);
  }

  void _text(
    Canvas canvas,
    String text,
    Offset offset, {
    required double fontSize,
    required Color color,
    bool bold = false,
  }) {
    (TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout())
        .paint(canvas, offset);
  }

  void _dashed(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dash = 6.0;
    const gap = 4.0;
    double x = start.dx;
    bool drawing = true;
    while (x < end.dx) {
      final next = x + (drawing ? dash : gap);
      if (drawing) {
        canvas.drawLine(
          Offset(x, start.dy),
          Offset(next.clamp(start.dx, end.dx), start.dy),
          paint,
        );
      }
      x = next;
      drawing = !drawing;
    }
  }

  String _fmt(DateTime d) {
    const months = [
      'janv', 'févr', 'mars', 'avr', 'mai', 'juin',
      'juil', 'août', 'sept', 'oct', 'nov', 'déc'
    ];
    return '${months[d.month - 1]} ${d.year}';
  }

  @override
  bool shouldRepaint(_ToisePainter old) =>
      old.measurements.length != measurements.length ||
      old.animalAreaW != animalAreaW;
}

// ─── Bouton Photo ─────────────────────────────────────────────────────────────

class _PhotoButton extends StatelessWidget {
  final ChildModel child;
  final String childId;
  final List<MilestoneModel> milestones;

  const _PhotoButton({
    required this.child,
    required this.childId,
    required this.milestones,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _openSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(
          color: AppColors.sage,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: AppColors.sage.withOpacity(0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.camera_alt_outlined, color: Colors.white, size: 22),
            SizedBox(width: 10),
            Text(
              'Ajouter une mesure par photo',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PhotoMeasureSheet(
        child: child,
        childId: childId,
        previousMeasurements: milestones,
      ),
    );
  }
}

// ─── Sheet Photo + Commentaire + IA ──────────────────────────────────────────

enum _SheetState { composing, analyzing, result }

class _PhotoMeasureSheet extends StatefulWidget {
  final ChildModel child;
  final String childId;
  final List<MilestoneModel> previousMeasurements;

  const _PhotoMeasureSheet({
    required this.child,
    required this.childId,
    required this.previousMeasurements,
  });

  @override
  State<_PhotoMeasureSheet> createState() => _PhotoMeasureSheetState();
}

class _PhotoMeasureSheetState extends State<_PhotoMeasureSheet> {
  _SheetState _state = _SheetState.composing;

  XFile? _photo;
  Uint8List? _photoBytes;
  GrowthAnalysis? _analysis;
  bool _aiSuccess = false;
  bool _saving = false;

  final _commentCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _commentCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 70,
      maxWidth: 900,
      maxHeight: 900,
    );
    if (xfile == null || !mounted) return;
    final bytes = await xfile.readAsBytes();
    setState(() {
      _photo = xfile;
      _photoBytes = bytes;
    });
  }

  bool get _canSend => _commentCtrl.text.trim().isNotEmpty;

  Future<void> _send() async {
    final comment = _commentCtrl.text.trim();
    if (comment.isEmpty) return;

    setState(() => _state = _SheetState.analyzing);

    final service = DeepSeekService();
    final result = await service.analyzeGrowthComment(
      comment: comment,
      childName: widget.child.firstName,
      previousMeasurements: widget.previousMeasurements,
    );

    if (!mounted) return;

    if (result != null) {
      _analysis = result;
      _aiSuccess = true;
      if (result.heightCm != null) {
        _heightCtrl.text = result.heightCm!.toStringAsFixed(0);
      }
      if (result.weightKg != null) {
        _weightCtrl.text = result.weightKg!.toStringAsFixed(1);
      }
    } else {
      _aiSuccess = false;
    }
    setState(() => _state = _SheetState.result);
  }

  Future<void> _save() async {
    final heightCm =
        double.tryParse(_heightCtrl.text.trim().replaceAll(',', '.'));
    final weightKg =
        double.tryParse(_weightCtrl.text.trim().replaceAll(',', '.'));

    if (heightCm == null && weightKg == null) return;

    final parts = <String>[];
    if (heightCm != null) parts.add('${heightCm.toStringAsFixed(0)} cm');
    if (weightKg != null) parts.add('${weightKg.toStringAsFixed(1)} kg');
    final comment = _commentCtrl.text.trim();

    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance.collection('milestones').add({
        'childId': widget.childId,
        'type': 'taille_poids',
        'subType': null,
        'date': Timestamp.fromDate(_date),
        'datePrecision': 'exact',
        'dateLabel': null,
        'rawContent': comment.isNotEmpty ? comment : parts.join(', '),
        'aiNarration': _analysis?.notes.isNotEmpty == true
            ? _analysis!.notes
            : null,
        'photoUrl': null,
        'weightKg': weightKg,
        'heightCm': heightCm,
        'createdAt': Timestamp.now(),
      });
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: widget.child.birthDate,
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                child: _state == _SheetState.analyzing
                    ? _buildAnalyzing()
                    : _state == _SheetState.result
                        ? _buildResult()
                        : _buildComposing(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Étape 1 : Photo + commentaire ─────────────────────────────────────────

  Widget _buildComposing() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Nouvelle mesure',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppColors.textDark,
            fontFamily: 'PlayfairDisplay',
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Décris la mesure en texte libre — l\'IA extrait la taille et le poids pour toi.',
          style: TextStyle(
              fontSize: 13, color: Colors.grey.shade500, height: 1.5),
        ),
        const SizedBox(height: 20),

        // Zone photo optionnelle
        GestureDetector(
          onTap: _takePhoto,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            height: _photoBytes != null ? 180 : 80,
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _photoBytes != null
                    ? AppColors.sage.withOpacity(0.3)
                    : Colors.grey.shade200,
                width: 1.5,
              ),
            ),
            child: _photoBytes != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(_photoBytes!, fit: BoxFit.cover),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: GestureDetector(
                            onTap: () =>
                                setState(() => _photoBytes = null),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close,
                                  color: Colors.white, size: 16),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: GestureDetector(
                            onTap: _takePhoto,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.camera_alt_outlined,
                                      color: Colors.white, size: 14),
                                  SizedBox(width: 4),
                                  Text('Changer',
                                      style: TextStyle(
                                          color: Colors.white, fontSize: 11)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.camera_alt_outlined,
                          color: Colors.grey.shade400, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        'Photo (optionnelle)',
                        style: TextStyle(
                            color: Colors.grey.shade400, fontSize: 13),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 16),

        // Commentaire
        TextField(
          controller: _commentCtrl,
          minLines: 3,
          maxLines: 5,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText:
                'Ex : "Nathan mesure 78 cm et pèse 11,5 kg chez le pédiatre"\nOu : "toise à la maison, 80 cm"',
            hintStyle:
                TextStyle(color: Colors.grey.shade400, fontSize: 13, height: 1.5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: AppColors.sage, width: 2),
            ),
            filled: true,
            fillColor: Colors.grey.shade50,
            contentPadding: const EdgeInsets.all(16),
          ),
        ),
        const SizedBox(height: 20),

        // Bouton Envoyer
        ElevatedButton.icon(
          onPressed: _canSend ? _send : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.sage,
            disabledBackgroundColor: Colors.grey.shade200,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: const Text(
            'Envoyer à l\'IA',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
      ],
    );
  }

  // ── Étape 2 : Analyse en cours ────────────────────────────────────────────

  Widget _buildAnalyzing() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 20),
        if (_photoBytes != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.memory(
              _photoBytes!,
              height: 160,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          ),
        SizedBox(height: _photoBytes != null ? 28 : 60),
        SvgPicture.asset(
          'assets/images/animals/${widget.child.animalId}.svg',
          width: 90,
        ),
        const SizedBox(height: 20),
        const CircularProgressIndicator(color: AppColors.sage),
        const SizedBox(height: 16),
        Text(
          "L'IA analyse le commentaire…",
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Extraction des mesures pour ${widget.child.firstName}',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
        ),
      ],
    );
  }

  // ── Étape 3 : Résultat éditable ───────────────────────────────────────────

  Widget _buildResult() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Photo si prise
        if (_photoBytes != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.memory(
              _photoBytes!,
              height: 140,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 14),
        ],

        // Badge IA
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _aiSuccess ? Colors.green.shade50 : Colors.orange.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _aiSuccess
                  ? Colors.green.shade200
                  : Colors.orange.shade200,
            ),
          ),
          child: Row(
            children: [
              Icon(
                _aiSuccess ? Icons.auto_awesome : Icons.edit_note,
                size: 16,
                color: _aiSuccess
                    ? Colors.green.shade700
                    : Colors.orange.shade700,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _aiSuccess
                      ? (_analysis?.notes.isNotEmpty == true
                          ? _analysis!.notes
                          : 'Valeurs extraites — vérifie et ajuste si besoin')
                      : 'L\'IA n\'a pas pu extraire les valeurs — entre-les manuellement',
                  style: TextStyle(
                    fontSize: 12,
                    color: _aiSuccess
                        ? Colors.green.shade700
                        : Colors.orange.shade700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Champs taille / poids
        const Text(
          'Valeurs mesurées',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: AppColors.textDark,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _MeasureField(
                controller: _heightCtrl,
                label: 'Taille',
                unit: 'cm',
                icon: Icons.height,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MeasureField(
                controller: _weightCtrl,
                label: 'Poids',
                unit: 'kg',
                icon: Icons.monitor_weight_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Date
        GestureDetector(
          onTap: _pickDate,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade200),
              borderRadius: BorderRadius.circular(12),
              color: Colors.grey.shade50,
            ),
            child: Row(
              children: [
                const Icon(Icons.calendar_today_outlined,
                    size: 18, color: AppColors.sage),
                const SizedBox(width: 10),
                Text(
                  '${_date.day.toString().padLeft(2, '0')}/${_date.month.toString().padLeft(2, '0')}/${_date.year}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark),
                ),
                const Spacer(),
                Text('Modifier',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade400)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),

        // Enregistrer
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.sage,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          child: _saving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2),
                )
              : const Text(
                  'Enregistrer la mesure',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
        ),
        const SizedBox(height: 10),

        // Recommencer
        TextButton.icon(
          onPressed: () => setState(() {
            _state = _SheetState.composing;
            _analysis = null;
            _heightCtrl.clear();
            _weightCtrl.clear();
          }),
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('Modifier le commentaire'),
          style:
              TextButton.styleFrom(foregroundColor: Colors.grey.shade500),
        ),
      ],
    );
  }
}

class _MeasureField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String unit;
  final IconData icon;

  const _MeasureField({
    required this.controller,
    required this.label,
    required this.unit,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: AppColors.textDark,
      ),
      decoration: InputDecoration(
        labelText: label,
        suffixText: unit,
        suffixStyle: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade500,
            fontWeight: FontWeight.w500),
        prefixIcon: Icon(icon, size: 18, color: AppColors.sage),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.sage, width: 2),
        ),
        filled: true,
        fillColor: Colors.grey.shade50,
      ),
    );
  }
}

// ─── Empty State ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final ChildModel child;
  final String childId;
  const _EmptyState({required this.child, required this.childId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(
              'assets/images/animals/${child.animalId}.svg',
              width: 120,
            ),
            const SizedBox(height: 24),
            Text(
              'Aucune mesure enregistrée',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Ajoute la première mesure de ${child.firstName}\navec le bouton photo !',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => _PhotoMeasureSheet(
                  child: child,
                  childId: childId,
                  previousMeasurements: const [],
                ),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    vertical: 14, horizontal: 24),
                decoration: BoxDecoration(
                  color: AppColors.sage,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.camera_alt_outlined,
                        color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Prendre une photo',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14),
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
}
