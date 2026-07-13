import 'dart:math' show min, max;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/data/growth_data.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/space_service.dart';
import '../../core/services/tag_service.dart';
import '../../core/utils/date_precision.dart';
import '../../core/widgets/date_mask_field.dart';

// Animaux disponibles en asset SVG (companion du carnet). Repli sur « bear ».
const _animalAssets = {'bear', 'dino', 'fox', 'mouse', 'penguin', 'rabbit'};
String _animalId(NotebookModel nb) =>
    _animalAssets.contains(nb.companion) ? nb.companion! : 'bear';

/// Écran Croissance / Suivi, branché sur un TAG.
/// - Tag « enfant » (il porte une date de naissance) : courbe OMS (taille +
///   poids) + toise visuelle.
/// - Autre tag : courbe de poids simple (suivi), sans percentiles.
/// Les mesures sont des `memories` de type `taille_poids` portant ce tag.
class GrowthScreen extends StatefulWidget {
  final String tagId;
  /// Ouvre directement la saisie d'une mesure au chargement.
  final bool startAddMeasure;
  const GrowthScreen({
    super.key,
    required this.tagId,
    this.startAddMeasure = false,
  });

  @override
  State<GrowthScreen> createState() => _GrowthScreenState();
}

class _GrowthScreenState extends State<GrowthScreen> {
  bool _autoOpened = false;

  void _openMeasureSheet(NotebookModel notebook) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _MeasureSheet(notebook: notebook, previousMeasures: const []),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TagModel?>(
      future: TagService.byId(widget.tagId),
      builder: (context, tagSnap) {
        if (!tagSnap.hasData && tagSnap.connectionState != ConnectionState.done) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final tag = tagSnap.data;
        if (tag == null) {
          return const Scaffold(body: Center(child: Text('Tag introuvable.')));
        }
        // Les écrans de courbes sont écrits pour un carnet : le tag leur en
        // fournit un (titre, couleur, date de naissance) sans rien persister.
        final notebook = tag.asNotebook();
        final isChild = tag.isChild && tag.birthdate != null;
        final name = tag.label;

        final body = StreamBuilder<List<MemoryModel>>(
          stream: MemoryQueryService.visibleWithTag(widget.tagId),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final measures = snap.data!
                .where((m) => m.type == 'taille_poids')
                .where((m) => m.heightCm != null || m.weightKg != null)
                .toList()
              ..sort((a, b) => a.date.compareTo(b.date));

            if (measures.isEmpty) {
              return _EmptyState(notebook: notebook, isChild: isChild);
            }

            if (!isChild) {
              // Suivi adulte : courbe de poids simple + historique + saisie.
              return _AdultWeightTab(notebook: notebook, measures: measures);
            }

            return _CurvesTab(notebook: notebook, measures: measures);
          },
        );

        // Ouverture auto de la saisie de mesure (depuis le menu « + » du carnet).
        if (widget.startAddMeasure && !_autoOpened) {
          _autoOpened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openMeasureSheet(notebook);
          });
        }

        return Scaffold(
          backgroundColor: AppColors.cream,
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openMeasureSheet(notebook),
            backgroundColor: AppColors.sage,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add),
            label: const Text('Nouvelle mesure'),
          ),
          appBar: AppBar(
            backgroundColor: AppColors.cream,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.pop(),
            ),
            title: Text(isChild ? 'Croissance de $name' : 'Suivi du poids'),
          ),
          body: body,
        );
      },
    );
  }
}

// ─── Curves Tab (enfant) ───────────────────────────────────────────────────────

class _CurvesTab extends StatefulWidget {
  final NotebookModel notebook;
  final List<MemoryModel> measures;
  const _CurvesTab({required this.notebook, required this.measures});

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
            notebook: widget.notebook,
            measures: widget.measures,
            showWeight: _showWeight,
          ),
          const SizedBox(height: 24),
          _MeasurementList(
            notebook: widget.notebook,
            measures: widget.measures,
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
        color: AppColors.cream,
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
                color: active ? AppColors.sage : AppColors.textMedium,
              ),
            ),
          ),
        ),
      );
}

class _MultiPointChart extends StatelessWidget {
  final NotebookModel notebook;
  final List<MemoryModel> measures;
  final bool showWeight;

  const _MultiPointChart({
    required this.notebook,
    required this.measures,
    required this.showWeight,
  });

  @override
  Widget build(BuildContext context) {
    final gender = notebook.gender ?? 'boy';
    // Date de naissance : si absente, on retombe sur la 1re mesure (axe d'âge
    // approximatif mais sans plantage).
    final birth = notebook.birthdate ?? measures.first.date;

    final refData = getGrowthData(gender: gender, isWeight: showWeight);
    final p3 = refData.map((p) => FlSpot(p.month.toDouble(), p.p3)).toList();
    final p50 = refData.map((p) => FlSpot(p.month.toDouble(), p.p50)).toList();
    final p97 = refData.map((p) => FlSpot(p.month.toDouble(), p.p97)).toList();

    final childSpots = measures
        .where((m) => showWeight ? m.weightKg != null : m.heightCm != null)
        .map((m) {
          final ageM = ((m.date.year - birth.year) * 12 +
                  m.date.month -
                  birth.month)
              .toDouble()
              .clamp(0.0, double.infinity);
          return FlSpot(ageM, showWeight ? m.weightKg! : m.heightCm!);
        })
        .toList();

    final unit = showWeight ? 'kg' : 'cm';

    final maxChildAge = childSpots.isEmpty
        ? 24.0
        : childSpots.map((s) => s.x).reduce(max);
    final maxX = (maxChildAge * 1.05).ceilToDouble().clamp(12.0, double.infinity);

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
                gender == 'boy' ? '👦' : '👧',
                style: const TextStyle(fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'OMS 2006 — P3, P50, P97',
            style: TextStyle(fontSize: 10, color: AppColors.softGray),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 220,
            child: LineChart(
              LineChartData(
                lineBarsData: [
                  _ref(p3, AppColors.border),
                  _ref(p50, AppColors.sage.withOpacity(0.35)),
                  _ref(p97, AppColors.border),
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
                      FlLine(color: AppColors.cream, strokeWidth: 1),
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
                            fontSize: 9, color: AppColors.softGray),
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
                            fontSize: 9, color: AppColors.softGray),
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

// ─── Suivi de poids (adulte / autres carnets) ──────────────────────────────────

class _AdultWeightTab extends StatelessWidget {
  final NotebookModel notebook;
  final List<MemoryModel> measures;
  const _AdultWeightTab({required this.notebook, required this.measures});

  @override
  Widget build(BuildContext context) {
    final wMeasures =
        measures.where((m) => m.weightKg != null).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SimpleWeightChart(measures: wMeasures),
          const SizedBox(height: 24),
          _MeasurementList(
              notebook: notebook, measures: measures, showWeight: true),
          const SizedBox(height: 20),
          _AddMeasureButton(notebook: notebook, measures: measures),
        ],
      ),
    );
  }
}

/// Courbe de poids simple (sans percentiles OMS) : poids dans le temps.
class _SimpleWeightChart extends StatelessWidget {
  final List<MemoryModel> measures;
  const _SimpleWeightChart({required this.measures});

  @override
  Widget build(BuildContext context) {
    if (measures.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.cream),
        ),
        child: Center(
          child: Text('Aucun poids enregistré',
              style: TextStyle(color: AppColors.softGray, fontSize: 13)),
        ),
      );
    }
    // X = ordre chronologique (0,1,2…), Y = poids. Labels de date sous l'axe.
    final spots = <FlSpot>[];
    for (var i = 0; i < measures.length; i++) {
      spots.add(FlSpot(i.toDouble(), measures[i].weightKg!));
    }
    final ys = measures.map((m) => m.weightKg!);
    final minY = (ys.reduce(min) - 2).clamp(0.0, double.infinity);
    final maxY = ys.reduce(max) + 2;

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
          const Text(
            'Poids (kg) dans le temps',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: AppColors.textDark),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 220,
            child: LineChart(
              LineChartData(
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: spots.length > 1,
                    color: AppColors.sage,
                    barWidth: 2.5,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
                        radius: 5,
                        color: AppColors.sage,
                        strokeWidth: 2,
                        strokeColor: Colors.white,
                      ),
                    ),
                  ),
                ],
                minX: 0,
                maxX: (measures.length - 1).toDouble().clamp(1.0, double.infinity),
                minY: minY,
                maxY: maxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: AppColors.cream, strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (v, _) => Text(
                        v.toStringAsFixed(0),
                        style: TextStyle(
                            fontSize: 9, color: AppColors.softGray),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= measures.length) {
                          return const SizedBox.shrink();
                        }
                        final d = measures[i].date;
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${d.day}/${d.month}',
                            style: TextStyle(
                                fontSize: 8, color: AppColors.softGray),
                          ),
                        );
                      },
                    ),
                  ),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeasurementList extends StatelessWidget {
  final NotebookModel notebook;
  final List<MemoryModel> measures;
  final bool showWeight;

  const _MeasurementList({
    required this.notebook,
    required this.measures,
    required this.showWeight,
  });

  void _edit(BuildContext context, MemoryModel m) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MeasureSheet(
        notebook: notebook,
        previousMeasures: const [],
        editing: m,
      ),
    );
  }

  String _label(MemoryModel m) =>
      m.dateLabel ??
      formatDateWithPrecision(
          m.date, datePrecisionFromString(m.datePrecision));

  @override
  Widget build(BuildContext context) {
    final items = measures
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
            style: TextStyle(color: AppColors.softGray, fontSize: 13),
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

          return GestureDetector(
            onTap: () => _edit(context, m),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color:
                    isLatest ? AppColors.sage.withOpacity(0.08) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isLatest
                      ? AppColors.sage.withOpacity(0.3)
                      : AppColors.cream,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: isLatest ? AppColors.sage : AppColors.cream,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      showWeight ? Icons.monitor_weight_outlined : Icons.height,
                      color: isLatest ? Colors.white : AppColors.softGray,
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
                            color:
                                isLatest ? AppColors.sage : AppColors.textDark,
                          ),
                        ),
                        Text(
                          _label(m),
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textMedium),
                        ),
                      ],
                    ),
                  ),
                  if (gain != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
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
                  const SizedBox(width: 6),
                  Icon(Icons.edit_outlined,
                      size: 16, color: AppColors.softGray),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

// ─── Bouton ajout de mesure ─────────────────────────────────────────────────────

class _AddMeasureButton extends StatelessWidget {
  final NotebookModel notebook;
  final List<MemoryModel> measures;

  const _AddMeasureButton({required this.notebook, required this.measures});

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
            Icon(Icons.add, color: Colors.white, size: 22),
            SizedBox(width: 10),
            Text(
              'Nouvelle mesure',
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
      builder: (_) => _MeasureSheet(
        notebook: notebook,
        previousMeasures: measures,
      ),
    );
  }
}

// ─── Sheet : saisie d'une mesure (enregistrée dans memories) ────────────────────

class _MeasureSheet extends StatefulWidget {
  final NotebookModel notebook;
  final List<MemoryModel> previousMeasures;
  /// Mesure existante à éditer (null = nouvelle mesure).
  final MemoryModel? editing;

  const _MeasureSheet({
    required this.notebook,
    required this.previousMeasures,
    this.editing,
  });

  @override
  State<_MeasureSheet> createState() => _MeasureSheetState();
}

class _MeasureSheetState extends State<_MeasureSheet> {
  bool _saving = false;
  bool _deleting = false;

  final _commentCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  DateTime _date = DateTime.now();

  bool get _isChild => widget.notebook.type == 'enfant';
  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      if (e.heightCm != null) _heightCtrl.text = e.heightCm!.toStringAsFixed(0);
      if (e.weightKg != null) _weightCtrl.text = e.weightKg!.toStringAsFixed(1);
      _date = e.date;
      // Pré-remplit la note seulement si rawContent n'est pas le texte auto
      // « 75 cm • 9.5 kg » (chiffres + unités uniquement).
      final raw = e.rawContent.trim();
      final looksAuto =
          RegExp(r'^[\d.,\s•×xcmkg]*$', caseSensitive: false).hasMatch(raw);
      if (raw.isNotEmpty && !looksAuto) _commentCtrl.text = raw;
    }
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    super.dispose();
  }

  bool get _canSave {
    final h = double.tryParse(_heightCtrl.text.trim().replaceAll(',', '.'));
    final w = double.tryParse(_weightCtrl.text.trim().replaceAll(',', '.'));
    return (h != null && h > 0) || (w != null && w > 0);
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
    final col = FirebaseFirestore.instance.collection('memories');
    // Le « carnet » reçu ici est celui synthétisé depuis le tag : son id EST
    // l'id du tag. La mesure est donc un souvenir tagué, rattaché à l'espace.
    final tagId = widget.notebook.id;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final spaceId = await SpaceService.ensureSpaceId() ?? '';
    final allTags = await TagService.visibleTags();
    final data = {
      'notebookId': spaceId,
      'userId': uid,
      'tagIds': [tagId],
      'tagLabels': [widget.notebook.title],
      'sharedWith': TagService.sharedUidsFor([tagId], allTags, uid),
      'type': 'taille_poids',
      'subType': null,
      'date': Timestamp.fromDate(_date),
      'datePrecision': 'exact',
      'dateLabel': null,
      'rawContent': comment.isNotEmpty ? comment : parts.join(', '),
      'aiNarration': null,
      'photoUrl': null,
      'mediaUrls': <String>[],
      'weightKg': weightKg,
      'heightCm': heightCm,
    };
    try {
      if (_isEditing) {
        // Édition : on met à jour la mesure existante (createdAt conservé).
        await col.doc(widget.editing!.id).update(data);
      } else {
        await col.add({...data, 'createdAt': Timestamp.now()});
      }
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Supprimer cette mesure ?'),
        content: const Text('Cette action est irréversible.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    try {
      await FirebaseFirestore.instance
          .collection('memories')
          .doc(widget.editing!.id)
          .delete();
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
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
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                child: _buildForm(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _isEditing ? 'Modifier la mesure' : 'Nouvelle mesure',
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppColors.textDark,
            fontFamily: 'PlayfairDisplay',
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _isChild
              ? 'Renseigne la taille et/ou le poids.'
              : 'Renseigne le poids.',
          style: TextStyle(
              fontSize: 13, color: AppColors.textMedium, height: 1.5),
        ),
        const SizedBox(height: 20),

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
            if (_isChild) ...[
              Expanded(
                child: _MeasureField(
                  controller: _heightCtrl,
                  label: 'Taille',
                  unit: 'cm',
                  icon: Icons.height,
                  onChanged: () => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: _MeasureField(
                controller: _weightCtrl,
                label: 'Poids',
                unit: 'kg',
                icon: Icons.monitor_weight_outlined,
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Date — saisie directe « JJ/MM/AAAA » (comme pour un nouveau souvenir).
        DateMaskField(
          label: 'Date',
          initialDate: _date,
          firstDate: widget.notebook.birthdate ?? DateTime(2000),
          lastDate: DateTime.now(),
          onChanged: (d) {
            if (d != null) setState(() => _date = d);
          },
        ),
        const SizedBox(height: 14),

        // Note (optionnelle)
        TextField(
          controller: _commentCtrl,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: 'Note (optionnel) — ex : visite chez le pédiatre',
            hintStyle: TextStyle(
                color: AppColors.softGray, fontSize: 13, height: 1.5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.sage, width: 2),
            ),
            filled: true,
            fillColor: AppColors.cream,
            contentPadding: const EdgeInsets.all(16),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: (_canSave && !_saving) ? _save : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.sage,
            disabledBackgroundColor: AppColors.border,
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
              : Text(
                  _isEditing ? 'Mettre à jour' : 'Enregistrer la mesure',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                ),
        ),
        if (_isEditing) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _deleting ? null : _delete,
            icon: _deleting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.error))
                : const Icon(Icons.delete_outline,
                    size: 18, color: AppColors.error),
            label: const Text('Supprimer cette mesure',
                style: TextStyle(color: AppColors.error)),
          ),
        ],
      ],
    );
  }
}

class _MeasureField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String unit;
  final IconData icon;
  final VoidCallback? onChanged;

  const _MeasureField({
    required this.controller,
    required this.label,
    required this.unit,
    required this.icon,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged == null ? null : (_) => onChanged!(),
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
            color: AppColors.textMedium,
            fontWeight: FontWeight.w500),
        prefixIcon: Icon(icon, size: 18, color: AppColors.sage),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.sage, width: 2),
        ),
        filled: true,
        fillColor: AppColors.cream,
      ),
    );
  }
}

// ─── Empty State ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final NotebookModel notebook;
  final bool isChild;
  const _EmptyState({required this.notebook, required this.isChild});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(
              'assets/images/animals/${_animalId(notebook)}.svg',
              width: 120,
            ),
            const SizedBox(height: 24),
            Text(
              isChild
                  ? 'Aucune mesure enregistrée'
                  : 'Aucun poids enregistré',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textMedium,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isChild
                  ? 'Ajoute la première mesure de ${notebook.title}'
                  : 'Ajoute un premier poids pour suivre l\'évolution',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.softGray),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => _MeasureSheet(
                  notebook: notebook,
                  previousMeasures: const [],
                ),
              ),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                decoration: BoxDecoration(
                  color: AppColors.sage,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Ajouter une mesure',
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
