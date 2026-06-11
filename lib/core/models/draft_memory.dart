import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/date_precision.dart';
import '../constants/milestone_types.dart';

class DraftMemory {
  String type;
  String? subType;
  DateTime? date;
  DatePrecision datePrecision;
  String rawContent;
  double? weightKg;
  double? heightCm;
  bool included;

  DraftMemory({
    required this.type,
    this.subType,
    this.date,
    this.datePrecision = DatePrecision.exact,
    required this.rawContent,
    this.weightKg,
    this.heightCm,
    this.included = true,
  });

  bool get needsDate => date == null;

  bool get needsSubType =>
      (type == 'parole' || type == 'mouvement') && subType == null;

  bool get isValid {
    if (date == null) return false;
    switch (type) {
      case 'parole':
        return subType != null;
      case 'mouvement':
        return subType != null;
      case 'taille_poids':
        return (weightKg != null && weightKg! > 0) ||
            (heightCm != null && heightCm! > 0);
      case 'anecdote':
        return rawContent.trim().isNotEmpty;
      default:
        return false;
    }
  }

  String buildRawContent() {
    switch (type) {
      case 'parole':
        final subLabel = getMilestoneSubTypeById(type, subType!)?.label ?? '';
        return rawContent.isNotEmpty ? '$subLabel : "$rawContent"' : subLabel;
      case 'mouvement':
        final subLabel = getMilestoneSubTypeById(type, subType!)?.label ?? '';
        return rawContent.isNotEmpty ? '$subLabel — $rawContent' : subLabel;
      case 'taille_poids':
        final parts = <String>[];
        if (weightKg != null) parts.add('${weightKg!.toStringAsFixed(1)} kg');
        if (heightCm != null) parts.add('${heightCm!.toStringAsFixed(1)} cm');
        return parts.join(' • ');
      default:
        return rawContent.trim();
    }
  }

  Map<String, dynamic> toFirestore(String notebookId) => {
        'notebookId': notebookId,
        'type': type,
        'subType': subType,
        'date': Timestamp.fromDate(date!),
        'datePrecision': datePrecisionToString(datePrecision),
        'dateLabel': formatDateWithPrecision(date!, datePrecision),
        'rawContent': buildRawContent(),
        'mediaUrls': [],
        'photoUrl': null,
        'weightKg': weightKg,
        'heightCm': heightCm,
        'aiNarration': null,
        'createdAt': FieldValue.serverTimestamp(),
      };
}
