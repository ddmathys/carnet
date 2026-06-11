import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Text field that auto-inserts '/' as the user types digits.
/// Typing "19012021" produces "19/01/2021".
class DateMaskField extends StatefulWidget {
  final String label;
  final DateTime? initialDate;
  final ValueChanged<DateTime?> onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool autofocus;

  const DateMaskField({
    super.key,
    required this.label,
    required this.onChanged,
    this.initialDate,
    this.firstDate,
    this.lastDate,
    this.autofocus = false,
  });

  @override
  State<DateMaskField> createState() => _DateMaskFieldState();
}

class _DateMaskFieldState extends State<DateMaskField> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.initialDate != null ? _fmt(widget.initialDate!) : '',
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}';

  void _onChanged(String value) {
    final digits = value.replaceAll('/', '');
    if (digits.length < 8) {
      if (_error != null) setState(() => _error = null);
      widget.onChanged(null);
      return;
    }

    // Full 8 digits: validate
    try {
      final day = int.parse(digits.substring(0, 2));
      final month = int.parse(digits.substring(2, 4));
      final year = int.parse(digits.substring(4, 8));
      final date = DateTime(year, month, day);

      // DateTime normalises invalid dates (e.g. 31/02 → March 3),
      // so we check the round-trip.
      if (date.day != day || date.month != month || date.year != year) {
        setState(() => _error = 'Date invalide');
        widget.onChanged(null);
        return;
      }

      final first = widget.firstDate;
      final last = widget.lastDate ?? DateTime.now();
      if (first != null && date.isBefore(first)) {
        setState(() =>
            _error = 'Avant le ${_fmt(first)}');
        widget.onChanged(null);
        return;
      }
      if (date.isAfter(last)) {
        setState(() => _error = 'Date dans le futur');
        widget.onChanged(null);
        return;
      }

      setState(() => _error = null);
      widget.onChanged(date);
    } catch (_) {
      setState(() => _error = 'Date invalide');
      widget.onChanged(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      keyboardType: TextInputType.number,
      autofocus: widget.autofocus,
      inputFormatters: [_DateMaskFormatter()],
      onChanged: _onChanged,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: 'JJ/MM/AAAA',
        errorText: _error,
        suffixIcon: const Icon(
          Icons.calendar_today_outlined,
          size: 18,
          color: AppColors.softGray,
        ),
      ),
    );
  }
}

/// Inserts '/' after day and month digits automatically.
class _DateMaskFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Strip everything except digits
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final capped = digits.length > 8 ? digits.substring(0, 8) : digits;

    final buf = StringBuffer();
    for (int i = 0; i < capped.length; i++) {
      if (i == 2 || i == 4) buf.write('/');
      buf.write(capped[i]);
    }

    final result = buf.toString();
    return TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
  }
}
