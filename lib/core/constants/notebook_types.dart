const kNotebookTypes = [
  NotebookType(
    id: 'enfant',
    label: 'Enfant',
    emoji: '🧒',
    description: 'Les premiers pas, les premières fois, le quotidien qui grandit trop vite.',
    whyThis: 'Conçu pour capturer chaque étape de 0 à l\'adolescence — avec compagnon, date de naissance et courbe de croissance.',
    memoryPlaceholder: 'Ex : Léa a dit "maman" pour la première fois ce matin…',
    hasCompanion: true,
    hasBirthdate: true,
    hasGender: true,
  ),
  NotebookType(
    id: 'voyage',
    label: 'Voyage',
    emoji: '🌍',
    description: 'Aventures, découvertes et moments de liberté loin de chez soi.',
    whyThis: 'Un carnet par destination. Parfait pour les souvenirs géo-localisés, les commentaires de lieux et les photos de voyage.',
    memoryPlaceholder: 'Ex : On a découvert une crique incroyable près de Split…',
    hasDestination: true,
  ),
  NotebookType(
    id: 'famille',
    label: 'Famille',
    emoji: '👨‍👩‍👧',
    description: 'Les nouvelles, les fous rires, les moments qui font la famille.',
    whyThis: 'Idéal pour une gazette partagée — petits et grands contribuent à la même histoire commune.',
    memoryPlaceholder: 'Ex : Mamie a fêté ses 80 ans entourée de toute la famille…',
    hasRecipient: true,
    hasFrequency: true,
  ),
  NotebookType(
    id: 'grossesse',
    label: 'Grossesse',
    emoji: '🤰',
    description: 'Neuf mois de sensations, d\'espoir et d\'émerveillement à ne jamais oublier.',
    whyThis: 'Semaine par semaine, de la conception à l\'accouchement. Le livre sera le plus beau cadeau de naissance.',
    memoryPlaceholder: 'Ex : Premiers coups de pied ce soir, 22 semaines…',
    hasBirthdate: true,
    hasGender: true,
    hasExpectedDate: true,
  ),
  NotebookType(
    id: 'moi',
    label: 'Moi',
    emoji: '🙋',
    description: 'Mes événements, mes objectifs, mon quotidien — un carnet rien que pour moi.',
    whyThis: 'Pour les adultes : tes moments perso, avec un suivi de poids dans le temps.',
    memoryPlaceholder: 'Ex : Objectif atteint, 72 kg ce matin…',
    hasWeightTracking: true,
  ),
  NotebookType(
    id: 'libre',
    label: 'Libre',
    emoji: '✨',
    description: 'Un carnet sans case. Projets, recettes, inspirations… tout ce qui ne rentre pas ailleurs.',
    whyThis: 'Aucune contrainte de format. Tu décides de ce que tu veux raconter et comment tu veux l\'organiser.',
    memoryPlaceholder: 'Écris ce qui te vient du cœur…',
  ),
];

NotebookType getNotebookTypeById(String id) =>
    kNotebookTypes.firstWhere((t) => t.id == id,
        orElse: () => kNotebookTypes.last);

class NotebookType {
  final String id;
  final String label;
  final String emoji;
  final String description;
  final String whyThis;
  final String memoryPlaceholder;
  final bool hasCompanion;
  final bool hasBirthdate;
  final bool hasGender;
  final bool hasDestination;
  final bool hasRecipient;
  final bool hasFrequency;
  final bool hasExpectedDate;
  // Carnet adulte « Moi » : expose une courbe de suivi de poids (sans OMS).
  final bool hasWeightTracking;

  const NotebookType({
    required this.id,
    required this.label,
    required this.emoji,
    required this.description,
    required this.whyThis,
    required this.memoryPlaceholder,
    this.hasCompanion = false,
    this.hasBirthdate = false,
    this.hasGender = false,
    this.hasDestination = false,
    this.hasRecipient = false,
    this.hasFrequency = false,
    this.hasExpectedDate = false,
    this.hasWeightTracking = false,
  });
}
