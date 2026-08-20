import 'dart:math' show min, max;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/models/notebook_model.dart';
import '../../../core/models/memory_model.dart';
import '../../../core/data/growth_data.dart';

/// Courbe de croissance multi-mesures (taille OU poids, avec percentiles OMS
/// P3/P50/P97 en fond) — LA courbe que le parent voit sur la page Croissance
/// (`/growth/:tagId`, onglet Courbes). Réutilisée telle quelle comme
/// prévisualisation dans la sélection de souvenirs du livre, pour que
/// l'image montrée soit toujours l'exacte même que celle déjà vue dans
/// l'app, générée à la volée depuis les mesures courantes (jamais un
/// instantané figé).
class GrowthMultiChart extends StatelessWidget {
  final NotebookModel notebook;
  final List<MemoryModel> measures;
  final bool showWeight;
  // Compact = pas de titre/légende interne (utilisé en aperçu, dans un cadre
  // qui porte déjà son propre titre) ; axes toujours affichés, plus fins.
  final bool compact;
  final double chartHeight;

  const GrowthMultiChart({
    super.key,
    required this.notebook,
    required this.measures,
    required this.showWeight,
    this.compact = false,
    this.chartHeight = 220,
  });

  @override
  Widget build(BuildContext context) {
    final gender = notebook.gender ?? 'boy';
    // Date de naissance : si absente, on retombe sur la 1re mesure (axe d'âge
    // approximatif mais sans plantage).
    final birth =
        notebook.birthdate ?? (measures.isNotEmpty ? measures.first.date : DateTime.now());

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
        .toList()
      ..sort((a, b) => a.x.compareTo(b.x));

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

    final chart = SizedBox(
      height: chartHeight,
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
                  getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
                    radius: compact ? 4 : 6,
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
                showTitles: !compact,
                reservedSize: 42,
                interval: yInterval,
                getTitlesWidget: (v, _) => Text(
                  showWeight ? v.toStringAsFixed(1) : '${v.toInt()}$unit',
                  style: TextStyle(fontSize: 9, color: AppColors.softGray),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: !compact,
                interval: xInterval,
                getTitlesWidget: (v, _) => Text(
                  '${v.toInt()}m',
                  style: TextStyle(fontSize: 9, color: AppColors.softGray),
                ),
              ),
            ),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          lineTouchData: LineTouchData(
            enabled: !compact && childSpots.isNotEmpty,
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
    );

    if (compact) return chart;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
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
          chart,
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
