import '../utils/date_precision.dart';

class ExtractedMilestone {
  final String type;
  final String? subType;
  final DateTime? date;
  final DatePrecision datePrecision;
  final String rawContent;
  final String? title;
  final String? location;
  final double? weightKg;
  final double? heightCm;

  const ExtractedMilestone({
    required this.type,
    this.subType,
    this.date,
    this.datePrecision = DatePrecision.exact,
    required this.rawContent,
    this.title,
    this.location,
    this.weightKg,
    this.heightCm,
  });
}
