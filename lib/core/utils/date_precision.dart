import 'package:intl/intl.dart';

enum DatePrecision { exact, month, quarter }

String formatDateWithPrecision(DateTime date, DatePrecision precision) {
  switch (precision) {
    case DatePrecision.exact:
      return DateFormat('d MMMM yyyy', 'fr').format(date);
    case DatePrecision.month:
      return DateFormat('MMMM yyyy', 'fr').format(date);
    case DatePrecision.quarter:
      final q = ((date.month - 1) ~/ 3) + 1;
      return 'T$q ${date.year}';
  }
}

DatePrecision datePrecisionFromString(String? s) {
  switch (s) {
    case 'month': return DatePrecision.month;
    case 'quarter': return DatePrecision.quarter;
    default: return DatePrecision.exact;
  }
}

String datePrecisionToString(DatePrecision p) {
  switch (p) {
    case DatePrecision.exact: return 'exact';
    case DatePrecision.month: return 'month';
    case DatePrecision.quarter: return 'quarter';
  }
}
