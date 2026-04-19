import 'dart:convert';
import 'package:http/http.dart' as http;

class ClaudeService {
  static const _apiUrl = 'https://api.anthropic.com/v1/messages';
  // Stocker la clé dans Firebase Remote Config ou via une Cloud Function en prod
  final String apiKey;

  ClaudeService({required this.apiKey});

  Future<String?> generateNarration({
    required String childName,
    required String birthDate,
    required String animalName,
    required String animalType,
    required String milestoneDate,
    required String rawContent,
  }) async {
    final prompt = '''Tu es le narrateur de Bloom, un journal de vie pour enfants.
Ton rôle est de transformer une note brute d'un parent en un passage littéraire chaleureux, poétique et intemporel, destiné à être lu dans 20 ans par l'enfant lui-même.

Règles strictes :
- Écris toujours à la 3e personne (ex: "$childName fit ses premiers pas...")
- Intègre l'animal compagnon $animalName le $animalType de façon naturelle dans la scène (comme témoin, complice, présence douce)
- Longueur : 3 à 5 phrases maximum
- Ton : tendre, littéraire, sans être mièvre
- Langue : français

Enfant : $childName, né(e) le $birthDate
Animal compagnon : $animalName le $animalType
Date du moment : $milestoneDate
Note du parent : $rawContent

Génère uniquement le texte narratif, sans titre ni introduction.''';

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
          'max_tokens': 300,
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
}
