import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/milestone_model.dart';
import '../models/memory_model.dart';
import '../models/notebook_model.dart';
import '../models/book_settings.dart';
import '../models/extracted_milestone.dart';
import '../models/draft_milestone.dart';
import '../constants/milestone_types.dart';
import '../utils/date_precision.dart';
import 'backend_client.dart';

class GrowthAnalysis {
  final double? heightCm;
  final double? weightKg;
  final String notes;
  const GrowthAnalysis({this.heightCm, this.weightKg, required this.notes});
}

/// Service de narration IA. Les appels passent par le backend Bloom
/// (authentifié Firebase) qui détient la clé API — jamais l'app.
class DeepSeekService {
  DeepSeekService();

  /// Appel générique au proxy IA du backend.
  Future<String?> _chat({
    String? system,
    required String user,
    required int maxTokens,
    double temperature = 0.7,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      final data = await BackendClient.postJson(
        '/api/ai/chat',
        {
          'messages': [
            if (system != null) {'role': 'system', 'content': system},
            {'role': 'user', 'content': user},
          ],
          'maxTokens': maxTokens,
          'temperature': temperature,
        },
        timeout: timeout,
      );
      return data?['content'] as String?;
    } catch (e) {
      debugPrint('[AI] _chat ERROR: $e');
      return null;
    }
  }

  Future<String?> generateMemoryBook({
    required String childName,
    required String gender,
    required DateTime birthDate,
    required List<MilestoneModel> milestones,
    BookSettings settings = const BookSettings(),
  }) async {
    final agreement = gender == 'girl' ? 'e' : '';
    final age = _formatAge(birthDate);
    const n = 5;

    final eventMilestones = [...milestones.where((m) => m.type != 'taille_poids')]
      ..sort((a, b) => a.date.compareTo(b.date));

    final buffer = StringBuffer();
    for (final m in eventMilestones) {
      final cat = getMilestoneCategoryById(m.type);
      final sub = m.subType != null ? getMilestoneSubTypeById(m.type, m.subType!) : null;
      final label = sub?.label ?? cat.label;
      final dateStr = m.dateLabel ??
          formatDateWithPrecision(m.date, datePrecisionFromString(m.datePrecision));
      final content = m.aiNarration?.isNotEmpty == true ? m.aiNarration! : m.rawContent;
      buffer.writeln('• [$dateStr] $label : $content');
    }

    final milestonesText =
        buffer.isEmpty ? '(aucun souvenir enregistré)' : buffer.toString();

    final phrasesPerSection = switch (settings.detail) {
      'brief' => '2 à 3 phrases',
      'detailed' => '5 à 6 phrases',
      _ => '3 à 4 phrases',
    };

    final toneInstruction = switch (settings.tone) {
      'intimate' => 'Style : journal intime de famille, chaleureux, personnel, comme si tu parlais à l\'enfant',
      'narrative' => 'Style : récit narratif clair, précis et factuel, sans fioritures poétiques',
      _ => 'Style : poétique et lyrique, avec des métaphores, chaleureux et littéraire',
    };

    final totalWords = switch (settings.detail) {
      'brief' => '200 à 300',
      'detailed' => '600 à 800',
      _ => '400 à 500',
    };

    final system =
        'Tu es l\'auteur de Folio, une application qui crée le livre de souvenirs illustré des enfants.\n'
        'Ta réponse contient exactement $n sections organisées CHRONOLOGIQUEMENT.\n'
        'Chaque section commence par un titre entre double astérisques (ex: **Naissance**, **Premiers mois**, etc.)\n'
        'suivi d\'un saut de ligne puis de $phrasesPerSection de narration.\n'
        'Les sections sont séparées par une ligne vide.\n'
        'Total : $totalWords mots.\n'
        'N\'invente pas de détails absents des souvenirs fournis.';

    final user = 'Crée l\'aperçu du livre de souvenirs pour $childName, un$agreement enfant de $age.\n'
        'Né$agreement le : ${_formatDate(birthDate)}\n\n'
        'Souvenirs enregistrés par ses parents (ordre chronologique) :\n'
        '$milestonesText\n\n'
        'Instructions :\n'
        '- Parle de $childName à la 3ème personne, accords ${gender == 'girl' ? 'féminins' : 'masculins'}\n'
        '- Organise en $n périodes chronologiques avec titres **en gras**\n'
        '- $toneInstruction\n'
        '- Termine par une phrase ouverte sur l\'avenir\n'
        '- Ne mentionne pas d\'animal compagnon dans le texte\n\n'
        'Format attendu ($n sections) :\n'
        '**Titre période 1**\n'
        'Texte $phrasesPerSection...\n\n'
        '**Titre période 2**\n'
        'Texte $phrasesPerSection...\n\n'
        '(exactement $n sections au total)';

    return _chat(
      system: system,
      user: user,
      maxTokens: 1500,
      temperature: 0.75,
      timeout: const Duration(seconds: 45),
    );
  }

  Future<String?> generateMemoryBookForNotebook({
    required NotebookModel notebook,
    required List<MemoryModel> memories,
    BookSettings settings = const BookSettings(),
  }) async {
    final eventMemories = memories
        .where((m) => m.type != 'taille_poids')
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final buffer = StringBuffer();
    for (final m in eventMemories) {
      final dateStr = m.dateLabel ??
          formatDateWithPrecision(m.date, datePrecisionFromString(m.datePrecision));
      final content = m.aiNarration?.isNotEmpty == true ? m.aiNarration! : m.rawContent;
      buffer.writeln('• [$dateStr] ${m.type} : $content');
    }
    final memoriesText =
        buffer.isEmpty ? '(aucun souvenir enregistré)' : buffer.toString();

    const n = 5;
    final phrasesPerSection = switch (settings.detail) {
      'brief' => '2 à 3 phrases',
      'detailed' => '5 à 6 phrases',
      _ => '3 à 4 phrases',
    };
    final toneInstruction = switch (settings.tone) {
      'intimate' => 'journal intime, chaleureux et personnel',
      'narrative' => 'récit narratif clair et factuel',
      _ => 'style poétique et littéraire',
    };

    final notebookContext = switch (notebook.type) {
      'voyage' => 'un carnet de voyage${notebook.destination != null ? " (${notebook.destination})" : ""}',
      'famille' => 'une gazette familiale',
      'grossesse' => 'un journal de grossesse',
      'scolaire' => 'un carnet des années scolaires',
      _ => 'un carnet de souvenirs',
    };

    final system =
        'Tu es l\'auteur de Folio, une application qui crée des livres de souvenirs.\n'
        'Ta réponse contient exactement $n sections organisées CHRONOLOGIQUEMENT.\n'
        'Chaque section commence par un titre entre double astérisques (ex: **Chapitre 1**)\n'
        'suivi d\'un saut de ligne puis de $phrasesPerSection de narration.\n'
        'Les sections sont séparées par une ligne vide.\n'
        'N\'invente pas de détails absents des souvenirs fournis.';

    final user = 'Crée le livre de souvenirs pour "${notebook.title}", $notebookContext.\n\n'
        'Souvenirs (ordre chronologique) :\n'
        '$memoriesText\n\n'
        'Instructions :\n'
        '- $toneInstruction\n'
        '- Organise en $n périodes chronologiques avec titres **en gras**\n'
        '- Termine par une phrase ouverte sur l\'avenir\n\n'
        'Format attendu ($n sections) :\n'
        '**Titre période 1**\nTexte...\n\n**Titre période 2**\nTexte...';

    return _chat(
      system: system,
      user: user,
      maxTokens: 1500,
      temperature: 0.75,
      timeout: const Duration(seconds: 45),
    );
  }

  /// Génère une courte description de lieu pour chaque souvenir ayant un champ location.
  /// Retourne un Map<memoryId, locationDescription>.
  Future<Map<String, String>> generateLocationComments({
    required List<MemoryModel> memories,
    String tone = 'poetic',
  }) async {
    final withLocation = memories.where(
      (m) => m.location != null && m.location!.trim().isNotEmpty,
    ).toList();
    if (withLocation.isEmpty) return {};

    final toneInstruction = switch (tone) {
      'intimate' => 'chaleureux et personnel, comme un journal de voyage',
      'narrative' => 'clair et factuel, ton descriptif',
      _ => 'poétique et évocateur, 1 à 2 phrases courtes',
    };

    final lines = withLocation.asMap().entries.map((e) {
      final m = e.value;
      return '[${e.key + 1}] Lieu : ${m.location!} — Contexte : ${m.rawContent.length > 80 ? m.rawContent.substring(0, 80) : m.rawContent}';
    }).join('\n');

    final system =
        'Tu crées de courtes descriptions de lieux pour un livre de souvenirs.\n'
        'Pour chaque lieu, écris 1 à 2 phrases courtes ($toneInstruction).\n'
        'Ne répète pas le lieu dans ta réponse. Ne mentionne pas de date.\n'
        'Format STRICT (une ligne par entrée) :\n'
        '[1] description du lieu\n'
        '[2] description du lieu\n'
        'Réponds uniquement en français.';

    final user = 'Génère une courte description pour chaque lieu :\n$lines';

    final text = await _chat(
      system: system,
      user: user,
      maxTokens: withLocation.length * 120,
      temperature: 0.6,
      timeout: const Duration(seconds: 30),
    );
    if (text == null) return {};

    final result = <String, String>{};
    for (final line in text.split('\n')) {
      final match = RegExp(r'^\[(\d+)\]\s*(.+)$').firstMatch(line.trim());
      if (match == null) continue;
      final idx = int.tryParse(match.group(1) ?? '');
      final desc = match.group(2)?.trim();
      if (idx != null && desc != null && idx >= 1 && idx <= withLocation.length) {
        result[withLocation[idx - 1].id] = desc;
      }
    }
    return result;
  }

  /// Enrichit les légendes des souvenirs photo avec du contexte (lieux, événements...).
  /// Retourne un Map<memoryId, enrichedCaption>.
  Future<Map<String, String>> enrichPhotoCaptions({
    required NotebookModel notebook,
    required List<MemoryModel> photoMemories,
  }) async {
    if (photoMemories.isEmpty) return {};

    // Build numbered list for the prompt
    final lines = <String>[];
    for (int i = 0; i < photoMemories.length; i++) {
      final m = photoMemories[i];
      final dateStr = m.dateLabel ??
          '${m.date.day.toString().padLeft(2, '0')}/${m.date.month.toString().padLeft(2, '0')}/${m.date.year}';
      lines.add('[${i + 1}] ($dateStr) ${m.rawContent}');
    }

    final system =
        'Tu enrichis les légendes photo d\'un carnet de souvenirs "${notebook.title}".\n'
        'Pour chaque légende :\n'
        '- Si un lieu est mentionné (ville, pays, monument) → ajoute 1-2 phrases de contexte géographique ou culturel\n'
        '- Si un événement est mentionné (fête, anniversaire, voyage) → ajoute du contexte\n'
        '- Conserve le ton chaleureux et personnel de l\'original\n'
        '- Maximum 3 phrases enrichies par légende\n'
        '- Réponds en français\n'
        'Format de réponse STRICT (une légende par ligne) :\n'
        '[1] texte enrichi\n'
        '[2] texte enrichi\n'
        '(etc.)';

    final user = 'Voici les légendes à enrichir :\n${lines.join('\n')}';

    final text = await _chat(
      system: system,
      user: user,
      maxTokens: photoMemories.length * 150,
      temperature: 0.5,
      timeout: const Duration(seconds: 45),
    );
    if (text == null) return {};

    // Parse [N] enriched text lines
    final result = <String, String>{};
    for (final line in text.split('\n')) {
      final match = RegExp(r'^\[(\d+)\]\s*(.+)$').firstMatch(line.trim());
      if (match == null) continue;
      final idx = int.tryParse(match.group(1) ?? '');
      final enriched = match.group(2)?.trim();
      if (idx != null && enriched != null && idx >= 1 && idx <= photoMemories.length) {
        result[photoMemories[idx - 1].id] = enriched;
      }
    }
    return result;
  }

  Future<String?> generateStory({
    required String childName,
    required String gender,
    required DateTime birthDate,
    required String animalName,
    required String animalType,
    required String animalEmoji,
    required String animalTraits,
    required List<MilestoneModel> milestones,
  }) async {
    final agreement = gender == 'girl' ? 'e' : '';
    final age = _formatAge(birthDate);

    // Tri par ordre développemental (catégorie), puis par date à intérieur
    final sorted = [...milestones]..sort((a, b) {
        final orderA = getMilestoneCategoryOrder(a.type);
        final orderB = getMilestoneCategoryOrder(b.type);
        if (orderA != orderB) return orderA.compareTo(orderB);
        return a.date.compareTo(b.date);
      });

    final buffer = StringBuffer();
    for (final m in sorted) {
      final cat = getMilestoneCategoryById(m.type);
      final sub = m.subType != null
          ? getMilestoneSubTypeById(m.type, m.subType!)
          : null;
      final label = sub?.label ?? cat.label;
      final dateStr = m.dateLabel ??
          formatDateWithPrecision(
              m.date, datePrecisionFromString(m.datePrecision));

      if (m.type == 'taille_poids') {
        final parts = <String>[];
        if (m.weightKg != null) {
          parts.add('${m.weightKg!.toStringAsFixed(1)} kg');
        }
        if (m.heightCm != null) {
          parts.add('${m.heightCm!.toStringAsFixed(1)} cm');
        }
        if (parts.isNotEmpty) {
          buffer.writeln('• [$dateStr] $label : ${parts.join(', ')}');
        }
      } else {
        final content = m.rawContent.isNotEmpty ? ' : ${m.rawContent}' : '';
        buffer.writeln('• [$dateStr] $label$content');
      }
    }

    final milestonesText = buffer.isEmpty
        ? '(aucun souvenir spécifique enregistré)'
        : buffer.toString();

    final system = '''Tu es l\'auteur de Folio, une application qui crée le livre de vie illustré des enfants.
Tu écris des histoires belles, poétiques et émouvantes en français, dans un style livre jeunesse premium.
Chaque histoire doit être divisée en exactement 5 paragraphes bien distincts, séparés par une ligne vide.
Chaque paragraphe fait 3 à 5 phrases. Total : 500 à 600 mots.''';

    final user = '''Écris une histoire en 5 paragraphes pour $childName, un$agreement enfant de $age.

Son compagnon fidèle est $animalEmoji $animalName le $animalType — $animalTraits.

Consignes :
- 3ème personne, accords ${gender == 'girl' ? 'féminins' : 'masculins'}
- 5 paragraphes séparés par une ligne vide
- Intègre les souvenirs ci-dessous dans l\'ordre donné (ordre développemental), de façon naturelle et poétique
- À chaque grande étape de la vie de $childName, tisse un parallèle subtil et poétique avec la nature ou le caractère de $animalName le $animalType ($animalTraits) — par exemple : sa façon d\'explorer, de grandir, de faire confiance. Ces comparaisons doivent être légères, jamais forcées
- Ton : chaleureux, magique, littéraire — comme un vrai livre pour enfants
- Termine par une phrase ouverte sur l\'avenir

Né$agreement le : ${_formatDate(birthDate)} — Âge : $age

Souvenirs (dans l\'ordre développemental) :
$milestonesText

Génère uniquement les 5 paragraphes, sans titre.''';

    return _chat(
      system: system,
      user: user,
      maxTokens: 1500,
      temperature: 0.85,
    );
  }

  Future<GrowthAnalysis?> analyzeGrowthComment({
    required String comment,
    required String childName,
    required List<MilestoneModel> previousMeasurements,
  }) async {
    final history = previousMeasurements
        .where((m) => m.heightCm != null || m.weightKg != null)
        .map((m) {
          final parts = <String>[];
          if (m.heightCm != null) parts.add('${m.heightCm!.toStringAsFixed(0)}cm');
          if (m.weightKg != null) parts.add('${m.weightKg!.toStringAsFixed(1)}kg');
          return '${_formatDate(m.date)}: ${parts.join(', ')}';
        })
        .join('\n');

    final prompt = '''Tu es un assistant de l'app Folio pour suivre la croissance des enfants.
${history.isNotEmpty ? 'Historique de $childName:\n$history\n\n' : ''}L'utilisateur a écrit: "$comment"

Extrais toute taille (en cm) et/ou poids (en kg) mentionnés dans ce message.
Réponds UNIQUEMENT en JSON valide, sans markdown ni explication:
{"heightCm": nombre ou null, "weightKg": nombre ou null, "notes": "résumé en 1 phrase de ce qui a été noté"}''';

    final content = await _chat(
      user: prompt,
      maxTokens: 150,
      temperature: 0.1,
      timeout: const Duration(seconds: 20),
    );
    if (content == null) return null;

    try {
      // Strip potential markdown code fences
      final jsonStr = content
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      final parsed = _decodeJson(jsonStr) as Map<String, dynamic>;
      return GrowthAnalysis(
        heightCm: (parsed['heightCm'] as num?)?.toDouble(),
        weightKg: (parsed['weightKg'] as num?)?.toDouble(),
        notes: parsed['notes'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<DraftMilestone>?> extractAllMilestonesFromText({
    required String text,
  }) async {
    const system =
        '''Tu es l\'assistant de Folio, application de journal de vie pour enfants.
Analyse le texte d\'un parent et extrais TOUS les souvenirs mentionnés.

Types disponibles (classe chaque souvenir dans le type le plus précis) :
- "naissance": naissance, date et lieu de naissance, premiers instants
- "retour_maison": retour à la maison, arrivée au foyer
- "premieres_nuits": premières nuits, sommeil du bébé, nuits difficiles ou réussies
- "premiers_repas": premiers repas, biberon, allaitement, tétée
- "premiers_sourires": premiers sourires, grimaces, expressions du visage
- "premiers_sons": premiers sons, gazouillis, babillage, vocalises
- "se_retourner": bébé qui se retourne seul pour la première fois
- "ramper": bébé qui rampe, se déplace sur le ventre
- "s_asseoir": bébé qui s\'assoit seul
- "premiers_pas": premiers pas, marche, se lever debout
- "premiers_mots": premiers mots, "maman", "papa", premiers mots
- "diversification": diversification alimentaire, premiers aliments solides, goûts
- "premier_anniversaire": premier anniversaire, 1 an
- "doudou": doudou ou objet préféré, attachement à un jouet ou objet
- "interactions_sociales": interactions avec d\'autres enfants, jeux avec d\'autres bébés
- "premieres_activites": premières activités, dessins, jeux, créativité
- "routine": routine quotidienne, bain, coucher, habitudes du soir
- "emotions_fortes": premières émotions intenses, colère, peur, joie intense
- "entree_creche": entrée en crèche, en école, séparation
- "grande_reussite": grande réussite, propreté, vélo, apprentissage important
- "taille_poids": mesures taille (cm) et/ou poids (kg). Pas de sous-type.
- "anecdote": tout souvenir qui ne correspond à aucun type ci-dessus. Pas de sous-type.

Réponds UNIQUEMENT avec un tableau JSON valide, sans markdown ni explication.
Chaque élément du tableau est un objet souvenir.''';

    final user = '''Texte du parent:
"""
$text
"""

Extrais TOUS les souvenirs et retourne ce tableau JSON:
[
  {
    "type": "un des types listés ci-dessus",
    "subType": null,
    "date": "YYYY-MM-DD si jour précis, YYYY-MM si mois/annee, YYYY-Qn si trimestre, null si absent",
    "datePrecision": "exact ou month ou quarter ou null",
    "rawContent": "description courte du souvenir en francais",
    "title": "titre court et accrocheur du souvenir (5 mots max), ou null",
    "location": "lieu précis mentionné dans le texte (ex: Zoo de Genève, Paris, Maison) ou null si absent",
    "weightKg": null,
    "heightCm": null
  }
]''';

    final content = await _chat(
      system: system,
      user: user,
      maxTokens: 6000,
      temperature: 0.1,
      timeout: const Duration(seconds: 60),
    );
    if (content == null) {
      debugPrint('[AI extractAll] no content');
      return null;
    }

    try {
      final raw = content
          .trim()
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      debugPrint('[AI extractAll] content=$raw');

      final decoded = _decodeJson(raw);
      final list = (decoded is List) ? decoded : [decoded];

      return list.map((item) {
        final m = item as Map<String, dynamic>;
        return DraftMilestone(
          type: m['type'] as String? ?? 'anecdote',
          subType: m['subType'] as String?,
          date: _parseDate(
            m['date'] as String?,
            m['datePrecision'] as String?,
          ),
          datePrecision: datePrecisionFromString(m['datePrecision'] as String?),
          rawContent: m['rawContent'] as String? ?? '',
          title: m['title'] as String?,
          location: m['location'] as String?,
          weightKg: (m['weightKg'] as num?)?.toDouble(),
          heightCm: (m['heightCm'] as num?)?.toDouble(),
        );
      }).toList();
    } catch (e, st) {
      debugPrint('[AI extractAll] ERROR: $e\n$st');
      return null;
    }
  }

  DateTime? _parseDate(String? dateStr, String? precStr) {
    if (dateStr == null) return null;
    final precision = datePrecisionFromString(precStr);
    if (precision == DatePrecision.quarter) {
      final parts = dateStr.split('-Q');
      if (parts.length == 2) {
        final year = int.tryParse(parts[0]);
        final quarter = int.tryParse(parts[1]);
        if (year != null && quarter != null) {
          return DateTime(year, (quarter - 1) * 3 + 1, 1);
        }
      }
      return null;
    }
    if (precision == DatePrecision.month) {
      final parts = dateStr.split('-');
      if (parts.length >= 2) {
        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        if (year != null && month != null) return DateTime(year, month, 1);
      }
      return null;
    }
    return DateTime.tryParse(dateStr);
  }

  Future<ExtractedMilestone?> extractMilestoneFromText({
    required String text,
  }) async {
    const system = '''Tu es l\'assistant de Folio, application de journal de vie pour enfants.
Analyse la note d\'un parent et extrais LE souvenir principal (un seul).

Types disponibles (choisis le plus précis) :
- "naissance": naissance, premiers instants
- "retour_maison": retour à la maison
- "premieres_nuits": premières nuits, sommeil
- "premiers_repas": biberon, allaitement, premiers repas
- "premiers_sourires": premiers sourires
- "premiers_sons": gazouillis, babillage
- "se_retourner": se retourner seul
- "ramper": ramper, se déplacer sur le ventre
- "s_asseoir": s\'asseoir seul
- "premiers_pas": premiers pas, marche
- "premiers_mots": premiers mots, "maman", "papa"
- "diversification": diversification alimentaire
- "premier_anniversaire": premier anniversaire
- "doudou": doudou ou objet préféré
- "interactions_sociales": interactions avec d\'autres enfants
- "premieres_activites": dessins, jeux, activités créatives
- "routine": routine bain, coucher, habitudes
- "emotions_fortes": colère, peur, joie intense
- "entree_creche": entrée en crèche ou école
- "grande_reussite": propreté, vélo, grande réussite
- "taille_poids": taille (cm) et/ou poids (kg)
- "anecdote": souvenir ne correspondant à aucun type ci-dessus

Réponds UNIQUEMENT avec un seul objet JSON valide (pas de tableau, pas de markdown, pas d\'explication).''';

    final user = '''Note du parent: "$text"

Extrais LE souvenir principal et retourne cet objet JSON (un seul objet, pas un tableau):
{
  "type": "un des types listés ci-dessus",
  "subType": null,
  "date": "YYYY-MM-DD si jour précis, YYYY-MM si mois/annee, YYYY-Qn si trimestre, null si absent",
  "datePrecision": "exact ou month ou quarter ou null",
  "rawContent": "description courte du souvenir en francais",
  "title": "titre court et accrocheur du souvenir (5 mots max), ou null",
  "location": "lieu précis mentionné dans le texte (ex: Zoo de Genève, Paris, Maison) ou null si absent",
  "weightKg": null,
  "heightCm": null
}''';

    final content = await _chat(
      system: system,
      user: user,
      maxTokens: 600,
      temperature: 0.1,
      timeout: const Duration(seconds: 20),
    );
    if (content == null) {
      debugPrint('[AI extract] no content');
      return null;
    }

    try {
      final raw = content
          .trim()
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      debugPrint('[AI extract] parsed content=$raw');
      final decoded = _decodeJson(raw);
      // Si le modèle retourne un tableau malgré la consigne, on prend le premier élément
      final parsed = (decoded is List)
          ? decoded.first as Map<String, dynamic>
          : decoded as Map<String, dynamic>;

      DateTime? date;
      DatePrecision precision = DatePrecision.exact;

      final precStr = parsed['datePrecision'] as String?;
      if (precStr != null) {
        precision = datePrecisionFromString(precStr);
      }

      final dateStr = parsed['date'] as String?;
      if (dateStr != null) {
        if (precision == DatePrecision.quarter) {
          // format YYYY-Qn → premier mois du trimestre
          final parts = dateStr.split('-Q');
          if (parts.length == 2) {
            final year = int.tryParse(parts[0]);
            final quarter = int.tryParse(parts[1]);
            if (year != null && quarter != null) {
              date = DateTime(year, (quarter - 1) * 3 + 1, 1);
            }
          }
        } else if (precision == DatePrecision.month) {
          // format YYYY-MM
          final parts = dateStr.split('-');
          if (parts.length >= 2) {
            final year = int.tryParse(parts[0]);
            final month = int.tryParse(parts[1]);
            if (year != null && month != null) {
              date = DateTime(year, month, 1);
            }
          }
        } else {
          date = DateTime.tryParse(dateStr);
        }
      }

      return ExtractedMilestone(
        type: parsed['type'] as String? ?? 'anecdote',
        subType: parsed['subType'] as String?,
        date: date,
        datePrecision: precision,
        rawContent: parsed['rawContent'] as String? ?? text,
        title: parsed['title'] as String?,
        location: parsed['location'] as String?,
        weightKg: (parsed['weightKg'] as num?)?.toDouble(),
        heightCm: (parsed['heightCm'] as num?)?.toDouble(),
      );
    } catch (e, st) {
      debugPrint('[AI extract] ERROR: $e\n$st');
      return null;
    }
  }

  dynamic _decodeJson(String raw) => jsonDecode(raw);

  String _formatAge(DateTime birth) {
    final now = DateTime.now();
    final months =
        (now.year - birth.year) * 12 + now.month - birth.month;
    if (months < 12) return '$months mois';
    final years = months ~/ 12;
    final rem = months % 12;
    if (rem == 0) return '$years an${years > 1 ? 's' : ''}';
    return '$years an${years > 1 ? 's' : ''} et $rem mois';
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
