/// Une entrée du carnet : un mot ou une phrase qu'on ne connaissait pas.
///
/// Deux choses distinctes portent le mot :
///  - [context] : la phrase réelle où on l'a croisé (le contexte) ;
///  - [category] : le thème qu'on lui donne soi-même (Voyage, Boulot…).
class VocabEntry {
  const VocabEntry({
    required this.id,
    required this.languageCode,
    required this.term,
    required this.translation,
    required this.context,
    required this.category,
    required this.createdAt,
    this.isLearned = false,
  });

  final String id;

  /// Code ISO de la langue à laquelle l'entrée appartient.
  final String languageCode;

  /// Le mot ou la phrase, dans la langue étudiée.
  final String term;

  /// Ce que ça veut dire.
  final String translation;

  /// La phrase où le mot a été rencontré. Vide si on ne l'a pas notée.
  final String context;

  /// Thème libre. Vide = « non classé ».
  final String category;

  final DateTime createdAt;

  /// Marqué comme acquis pendant une révision.
  final bool isLearned;

  VocabEntry copyWith({
    String? languageCode,
    String? term,
    String? translation,
    String? context,
    String? category,
    bool? isLearned,
  }) {
    return VocabEntry(
      id: id,
      languageCode: languageCode ?? this.languageCode,
      term: term ?? this.term,
      translation: translation ?? this.translation,
      context: context ?? this.context,
      category: category ?? this.category,
      createdAt: createdAt,
      isLearned: isLearned ?? this.isLearned,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'lang': languageCode,
        'term': term,
        'translation': translation,
        'context': context,
        'category': category,
        'createdAt': createdAt.toIso8601String(),
        'isLearned': isLearned,
      };

  /// Relit une entrée. Tolérante : un champ manquant ou d'un type inattendu
  /// (carnet écrit par une version précédente) donne une valeur par défaut
  /// plutôt qu'une exception qui viderait tout le carnet au démarrage.
  factory VocabEntry.fromJson(Map<String, dynamic> json) {
    return VocabEntry(
      id: _string(json['id']),
      languageCode: _string(json['lang']),
      term: _string(json['term']),
      translation: _string(json['translation']),
      context: _string(json['context']),
      category: _string(json['category']),
      createdAt: DateTime.tryParse(_string(json['createdAt'])) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      isLearned: json['isLearned'] == true,
    );
  }

  static String _string(Object? value) => value is String ? value : '';

  /// Vrai si l'entrée répond à une recherche libre. On cherche dans le mot,
  /// la traduction, le contexte et le thème : taper « marché » doit ressortir
  /// l'entrée même si le mot cherché est dans la phrase d'exemple.
  bool matches(String query) {
    final String needle = foldForSearch(query);
    if (needle.isEmpty) return true;
    return foldForSearch(term).contains(needle) ||
        foldForSearch(translation).contains(needle) ||
        foldForSearch(context).contains(needle) ||
        foldForSearch(category).contains(needle);
  }
}

const Map<String, String> _accents = <String, String>{
  'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ñ': 'n', 'ç': 'c', 'ß': 's',
};

/// Minuscules + accents retirés, pour que « cafe » retrouve « café ».
String foldForSearch(String value) {
  final StringBuffer buffer = StringBuffer();
  for (final String char in value.toLowerCase().split('')) {
    buffer.write(_accents[char] ?? char);
  }
  return buffer.toString().trim();
}
