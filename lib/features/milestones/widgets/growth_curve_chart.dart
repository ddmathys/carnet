import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/data/growth_data.dart';
import '../../../core/theme/app_theme.dart';

class GrowthCurveChart extends StatelessWidget {
  final String gender;
  final bool isWeight; // true=poids, false=taille
  final int ageMonths;
  final double? value;

  const GrowthCurveChart({
    super.key,
    required this.gender,
    required this.isWeight,
    required this.ageMonths,
    this.value,
  });

  @override
  Widget build(BuildContext context) {
    final data = getGrowthData(gender: gender, isWeight: isWeight);

    final p3Spots = data.map((p) => FlSpot(p.month.toDouble(), p.p3)).toList();
    final p50Spots = data.map((p) => FlSpot(p.month.toDouble(), p.p50)).toList();
    final p97Spots = data.map((p) => FlSpot(p.month.toDouble(), p.p97)).toList();

    final minY = isWeight ? 1.5 : 40.0;
    final maxY = isWeight ? 16.0 : 100.0;
    final unit = isWeight ? 'kg' : 'cm';

    final bars = <LineChartBarData>[
      _refLine(p3Spots, Colors.grey.shade300),
      _refLine(p50Spots, AppColors.sage.withOpacity(0.5)),
      _refLine(p97Spots, Colors.grey.shade300),
    ];

    if (value != null && value! > 0) {
      bars.add(LineChartBarData(
        spots: [FlSpot(ageMonths.toDouble(), value!)],
        isCurved: false,
        color: AppColors.sage,
        barWidth: 0,
        dotData: FlDotData(
          show: true,
          getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
            radius: 7,
            color: AppColors.sage,
            strokeWidth: 2,
            strokeColor: AppColors.white,
          ),
        ),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              isWeight ? 'Courbe de poids' : 'Courbe de taille',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textDark,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              gender == 'boy' ? '👦' : '👧',
              style: const TextStyle(fontSize: 14),
            ),
            const Spacer(),
            _Legend(),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 180,
          child: LineChart(
            LineChartData(
              lineBarsData: bars,
              minX: 0,
              maxX: 24,
              minY: minY,
              maxY: maxY,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: isWeight ? 2 : 10,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: Colors.grey.shade100,
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    interval: isWeight ? 4 : 20,
                    getTitlesWidget: (v, _) => Text(
                      '${v.toInt()}$unit',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: 6,
                    getTitlesWidget: (v, _) => Text(
                      '${v.toInt()}m',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ),
                ),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              lineTouchData: LineTouchData(
                enabled: value != null,
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots
                      .where((s) => s.barIndex == 3)
                      .map((s) => LineTooltipItem(
                            '${s.y.toStringAsFixed(1)} $unit',
                            const TextStyle(
                              color: AppColors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ))
                      .toList(),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Source : OMS 2006 — courbes de référence P3, P50, P97',
          style: TextStyle(fontSize: 9, color: Colors.grey.shade400),
        ),
      ],
    );
  }

  LineChartBarData _refLine(List<FlSpot> spots, Color color) {
    return LineChartBarData(
      spots: spots,
      isCurved: true,
      color: color,
      barWidth: 1.5,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(show: false),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _dot(Colors.grey.shade300),
        const SizedBox(width: 2),
        Text('P3/P97', style: TextStyle(fontSize: 9, color: Colors.grey.shade400)),
        const SizedBox(width: 6),
        _dot(AppColors.sage.withOpacity(0.5)),
        const SizedBox(width: 2),
        Text('P50', style: TextStyle(fontSize: 9, color: Colors.grey.shade400)),
        const SizedBox(width: 6),
        _dot(AppColors.sage),
        const SizedBox(width: 2),
        Text('Enfant', style: TextStyle(fontSize: 9, color: Colors.grey.shade400)),
      ],
    );
  }

  Widget _dot(Color color) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}
