import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/date_precision.dart';

class FlexibleDateSheet extends StatefulWidget {
  final DateTime currentDate;
  final DatePrecision currentPrecision;
  final DateTime minDate;

  const FlexibleDateSheet({
    super.key,
    required this.currentDate,
    required this.currentPrecision,
    required this.minDate,
  });

  @override
  State<FlexibleDateSheet> createState() => _FlexibleDateSheetState();
}

class _FlexibleDateSheetState extends State<FlexibleDateSheet> {
  late DatePrecision _precision;
  late int _year;
  late int _month;
  late int _quarter;

  @override
  void initState() {
    super.initState();
    _precision = widget.currentPrecision;
    _year = widget.currentDate.year;
    _month = widget.currentDate.month;
    _quarter = ((widget.currentDate.month - 1) ~/ 3) + 1;
  }

  int get _currentYear => DateTime.now().year;
  int get _minYear => widget.minDate.year;

  void _confirm() {
    if (_precision == DatePrecision.exact) {
      Navigator.pop(context, {'precision': DatePrecision.exact});
      return;
    }
    final date = _precision == DatePrecision.month
        ? DateTime(_year, _month, 1)
        : DateTime(_year, (_quarter - 1) * 3 + 1, 1);
    Navigator.pop(context, {'precision': _precision, 'date': date});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.beige,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Quand est-ce arrivé ?',
            style: TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              PrecisionChip(
                label: 'Date exacte',
                selected: _precision == DatePrecision.exact,
                onTap: () => setState(() => _precision = DatePrecision.exact),
              ),
              const SizedBox(width: 8),
              PrecisionChip(
                label: 'Mois / Année',
                selected: _precision == DatePrecision.month,
                onTap: () => setState(() => _precision = DatePrecision.month),
              ),
              const SizedBox(width: 8),
              PrecisionChip(
                label: 'Trimestre',
                selected: _precision == DatePrecision.quarter,
                onTap: () => setState(() => _precision = DatePrecision.quarter),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_precision == DatePrecision.exact) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.beige,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.calendar_today_outlined,
                      color: AppColors.textMedium, size: 18),
                  SizedBox(width: 10),
                  Text(
                    'La date exacte s\'ouvrira après confirmation.',
                    style: TextStyle(color: AppColors.textMedium, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed:
                      _year > _minYear ? () => setState(() => _year--) : null,
                  icon: const Icon(Icons.chevron_left),
                  color: AppColors.sage,
                ),
                Text(
                  '$_year',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                ),
                IconButton(
                  onPressed:
                      _year < _currentYear ? () => setState(() => _year++) : null,
                  icon: const Icon(Icons.chevron_right),
                  color: AppColors.sage,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_precision == DatePrecision.month) _buildMonthGrid(),
            if (_precision == DatePrecision.quarter) _buildQuarterGrid(),
            const SizedBox(height: 16),
          ],
          ElevatedButton(
            onPressed: _confirm,
            child: const Text('Confirmer'),
          ),
        ],
      ),
    );
  }

  static const _monthLabels = [
    'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin',
    'Juil', 'Août', 'Sep', 'Oct', 'Nov', 'Déc'
  ];

  Widget _buildMonthGrid() {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 4,
      childAspectRatio: 1.8,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: List.generate(12, (i) {
        final m = i + 1;
        final selected = _month == m;
        return GestureDetector(
          onTap: () => setState(() => _month = m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: selected ? AppColors.sage : AppColors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: selected ? AppColors.sage : AppColors.beige),
            ),
            alignment: Alignment.center,
            child: Text(
              _monthLabels[i],
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: selected ? AppColors.white : AppColors.textMedium,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildQuarterGrid() {
    return Row(
      children: List.generate(4, (i) {
        final q = i + 1;
        final selected = _quarter == q;
        return Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _quarter = q),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: EdgeInsets.only(right: i < 3 ? 8 : 0),
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: selected ? AppColors.sage : AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: selected ? AppColors.sage : AppColors.beige),
              ),
              alignment: Alignment.center,
              child: Text(
                'T$q',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: selected ? AppColors.white : AppColors.textMedium,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class PrecisionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const PrecisionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.sage : AppColors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected ? AppColors.sage : AppColors.beige),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected ? AppColors.white : AppColors.textMedium,
          ),
        ),
      ),
    );
  }
}
