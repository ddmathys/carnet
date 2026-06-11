import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/milestone_model.dart';
import '../constants/milestone_types.dart';
import '../utils/date_precision.dart';

class ClaudeService {
  static const _apiUrl = 'https://api.anthropic.com/v1/messages';
  final String apiKey;

  ClaudeService({required this.apiKey});

  // ── Narration courte d'un souvenir ────────────────────────────────────────

  Future<String?> generateNarration({
    required String childName,
    required String birthDate,
    required String animalName,
    required String animalType,
    required String milestoneDate,
    required String rawContent,
  }) async {
    final prompt = '''Tu es le narrateur de Folio, un journal de vie pour enfants.
Transforme cette note brute en un passage littéraire chaleureux (3 à 5 phrases max).
Écris à la 3e personne, intègre $animalName le $animalType naturellement dans la scène.
Ton : tendre, poétique, intemporel. Langue : français.

Enfant : $childName, né(e) le $birthDate
Note : $rawContent
Date : $milestoneDate

Génère uniquement le texte narratif.''';

    return _call(prompt, maxTokens: 300);
  }

  // ── Histoire complète ─────────────────────────────────────────────────────

  Future<String?> generateStory({
    required String childName,
    required String gender, // 'boy' | 'girl'
    required DateTime birthDate,
    required String animalName,
    required String animalType,
    required String animalEmoji,
    required List<MilestoneModel> milestones,
  }) async {
    final pronoun = gender == 'girl' ? 'elle' : 'il';
    final pronounCap = gender == 'girl' ? 'Elle' : 'Il';
    final agreement = gender == 'girl' ? 'e' : '';
    final age = _formatAge(birthDate);

    // Construction de la timeline des souvenirs
    final sorted = [...milestones]..sort((a, b) => a.date.compareTo(b.date));
    final buffer = StringBuffer();
    for (final m in sorted) {
      final cat = getMilestoneCategoryById(m.type);
      final sub = m.subType != null
          ? getMilestoneSubTypeById(m.type, m.subType!)
          : null;
      final label = sub?.label ?? cat.label;
      final dateStr = m.dateLabel ??
          formatDateWithPrecision(m.date, datePrecisionFromString(m.datePrecision));

      if (m.type == 'taille_poids') {
        final parts = <String>[];
        if (m.weightKg != null) parts.add('${m.weightKg!.toStringAsFixed(1)} kg');
        if (m.heightCm != null) parts.add('${m.heightCm!.toStringAsFixed(1)} cm');
        if (parts.isNotEmpty) {
          buffer.writeln('• [$dateStr] $label : ${parts.join(', ')}');
        }
      } else if (m.rawContent.isNotEmpty) {
        buffer.writeln('• [$dateStr] $label : ${m.rawContent}');
      }
    }

    final milestonesText = buffer.isEmpty
        ? '(aucun souvenir enregistré pour l\'instant)'
        : buffer.toString();

    final prompt = '''Tu es l'auteur de Folio, une application qui crée le livre de vie des enfants.

Écris une histoire belle et complète (500 à 700 mots) qui raconte la vie de $childName depuis sa naissance jusqu'à aujourd'hui. Cette histoire sera lue dans 20 ans par $childName lui-même.

Consignes :
- Écris à la 3ème personne ("$childName fit...", "$pronounCap découvrit...")
- Le genre est ${gender == 'girl' ? 'féminin' : 'masculin'} (utilise les bons accords)
- $animalEmoji $animalName le $animalType est le compagnon fidèle de $childName — il/elle est présent${agreement} dans chaque moment important, comme témoin complice de cette aventure
- Intègre les vrais souvenirs ci-dessous de façon naturelle dans le récit, dans l'ordre chronologique
- Chaque souvenir doit devenir une scène vivante et poétique, pas une simple liste
- Ton : chaleureux, littéraire, un peu magique — comme un vrai livre pour enfants
- Langue : français soigné
- Termine par une phrase ouverte sur l'avenir, pleine de promesses

Informations :
- Prénom : $childName
- Né$agreement le : ${_formatDate(birthDate)}
- Âge : $age
- Compagnon : $animalEmoji $animalName le $animalType

Souvenirs à intégrer (chronologiques) :
$milestonesText

Génère uniquement l'histoire, sans titre. Commence directement par le récit.''';

    return _call(prompt, maxTokens: 1200);
  }

  // ── Appel HTTP ────────────────────────────────────────────────────────────

  Future<String?> _call(String prompt, {required int maxTokens}) async {
    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'model': 'claude-sonnet-4-6',
          'max_tokens': maxTokens,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['content'][0]['text'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _formatAge(DateTime birth) {
    final now = DateTime.now();
    final months = (now.year - birth.year) * 12 + now.month - birth.month;
    if (months < 12) return '$months mois';
    final years = months ~/ 12;
    final rem = months % 12;
    if (rem == 0) return '$years an${years > 1 ? 's' : ''}';
    return '$years an${years > 1 ? 's' : ''} et $rem mois';
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
