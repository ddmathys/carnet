/// Une langue qu'on peut apprendre.
///
/// La liste est figée dans le code : un MVP n'a pas besoin d'un catalogue
/// paramétrable, et le code ISO sert de clé de rangement des entrées.
class Language {
  const Language({required this.code, required this.name, required this.flag});

  /// Code ISO 639-1 (`es`, `de`…). C'est la clé stockée dans chaque entrée.
  final String code;

  /// Nom affiché, en français.
  final String name;

  /// Drapeau emoji — évite d'embarquer des images pour le MVP.
  final String flag;

  String get label => '$flag  $name';
}

/// Les langues proposées à la sélection.
const List<Language> kLanguages = <Language>[
  Language(code: 'en', name: 'Anglais', flag: '🇬🇧'),
  Language(code: 'es', name: 'Espagnol', flag: '🇪🇸'),
  Language(code: 'de', name: 'Allemand', flag: '🇩🇪'),
  Language(code: 'it', name: 'Italien', flag: '🇮🇹'),
  Language(code: 'pt', name: 'Portugais', flag: '🇵🇹'),
  Language(code: 'nl', name: 'Néerlandais', flag: '🇳🇱'),
  Language(code: 'sv', name: 'Suédois', flag: '🇸🇪'),
  Language(code: 'pl', name: 'Polonais', flag: '🇵🇱'),
  Language(code: 'el', name: 'Grec', flag: '🇬🇷'),
  Language(code: 'tr', name: 'Turc', flag: '🇹🇷'),
  Language(code: 'ru', name: 'Russe', flag: '🇷🇺'),
  Language(code: 'ar', name: 'Arabe', flag: '🇸🇦'),
  Language(code: 'he', name: 'Hébreu', flag: '🇮🇱'),
  Language(code: 'hi', name: 'Hindi', flag: '🇮🇳'),
  Language(code: 'ja', name: 'Japonais', flag: '🇯🇵'),
  Language(code: 'zh', name: 'Chinois', flag: '🇨🇳'),
  Language(code: 'ko', name: 'Coréen', flag: '🇰🇷'),
  Language(code: 'vi', name: 'Vietnamien', flag: '🇻🇳'),
  Language(code: 'th', name: 'Thaï', flag: '🇹🇭'),
  Language(code: 'fr', name: 'Français', flag: '🇫🇷'),
];

/// Retrouve une langue par son code. Renvoie une langue « inconnue » plutôt
/// que `null` : un code orphelin (carnet importé, liste modifiée) ne doit
/// jamais faire planter un écran.
Language languageByCode(String code) {
  for (final Language language in kLanguages) {
    if (language.code == code) return language;
  }
  return Language(code: code, name: code.toUpperCase(), flag: '🏳️');
}
