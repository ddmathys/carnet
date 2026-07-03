class MilestoneSubType {
  final String id;
  final String label;
  final bool hasFreeText;

  const MilestoneSubType({
    required this.id,
    required this.label,
    this.hasFreeText = false,
  });
}

class MilestoneCategory {
  final String id;
  final String label;
  final String emoji;
  final String description;
  final List<MilestoneSubType> subTypes;
  final bool isLegacy;

  const MilestoneCategory({
    required this.id,
    required this.label,
    required this.emoji,
    this.description = '',
    this.subTypes = const [],
    this.isLegacy = false,
  });
}

const List<MilestoneCategory> kMilestoneCategories = [
  // ── 20 catégories principales (ordre développemental) ──────────────────────
  MilestoneCategory(
    id: 'naissance',
    label: 'Naissance',
    emoji: '🍼',
    description: 'Date, lieu, premières émotions',
  ),
  MilestoneCategory(
    id: 'retour_maison',
    label: 'Retour à la maison',
    emoji: '🏡',
    description: 'Découverte du cocon familial',
  ),
  MilestoneCategory(
    id: 'premieres_nuits',
    label: 'Premières nuits',
    emoji: '😴',
    description: 'Sommeil (ou pas 😅)',
  ),
  MilestoneCategory(
    id: 'premiers_repas',
    label: 'Premiers repas',
    emoji: '🍼',
    description: 'Biberon, allaitement',
  ),
  MilestoneCategory(
    id: 'premiers_sourires',
    label: 'Premiers sourires',
    emoji: '😊',
    description: 'Interaction avec les parents',
  ),
  MilestoneCategory(
    id: 'premiers_sons',
    label: 'Premiers sons',
    emoji: '🗣️',
    description: 'Gazouillis, babillage',
  ),
  MilestoneCategory(
    id: 'se_retourner',
    label: 'Se retourner',
    emoji: '🔄',
    description: 'Première mobilité',
  ),
  MilestoneCategory(
    id: 'ramper',
    label: 'Ramper',
    emoji: '🧎',
    description: 'Exploration du monde',
  ),
  MilestoneCategory(
    id: 's_asseoir',
    label: "S'asseoir",
    emoji: '🪑',
    description: 'Autonomie qui commence',
  ),
  MilestoneCategory(
    id: 'premiers_pas',
    label: 'Premiers pas',
    emoji: '👣',
    description: 'Moment clé émotionnel',
  ),
  MilestoneCategory(
    id: 'premiers_mots',
    label: 'Premiers mots',
    emoji: '🗨️',
    description: '"maman", "papa", etc.',
  ),
  MilestoneCategory(
    id: 'diversification',
    label: 'Diversification alimentaire',
    emoji: '🍽️',
    description: 'Découverte des goûts',
  ),
  MilestoneCategory(
    id: 'premier_anniversaire',
    label: 'Premier anniversaire',
    emoji: '🎂',
    description: 'Grande étape symbolique',
  ),
  MilestoneCategory(
    id: 'doudou',
    label: 'Objet ou doudou préféré',
    emoji: '🧸',
    description: 'Attachement émotionnel',
  ),
  MilestoneCategory(
    id: 'interactions_sociales',
    label: 'Premières interactions',
    emoji: '👶',
    description: 'Avec d\'autres enfants',
  ),
  MilestoneCategory(
    id: 'premieres_activites',
    label: 'Premières activités',
    emoji: '🎨',
    description: 'Dessins, jeux, créativité',
  ),
  MilestoneCategory(
    id: 'routine',
    label: 'Routine quotidienne',
    emoji: '🚿',
    description: 'Bain, coucher, habitudes',
  ),
  MilestoneCategory(
    id: 'emotions_fortes',
    label: 'Premières émotions fortes',
    emoji: '😡',
    description: 'Colère, peur, joie intense',
  ),
  MilestoneCategory(
    id: 'entree_creche',
    label: 'Entrée en crèche / école',
    emoji: '🏫',
    description: 'Séparation + nouvelle phase',
  ),
  MilestoneCategory(
    id: 'grande_reussite',
    label: 'Première grande réussite',
    emoji: '🌟',
    description: 'Propre, vélo, apprentissage clé',
  ),

  // ── Catégories legacy (rétrocompatibilité Firestore) ───────────────────────
  MilestoneCategory(
    id: 'parole',
    label: 'Première parole',
    emoji: '💬',
    isLegacy: true,
    subTypes: [
      MilestoneSubType(id: 'premier_mot', label: 'Premier mot', hasFreeText: true),
      MilestoneSubType(id: 'premiere_phrase', label: 'Première phrase', hasFreeText: true),
      MilestoneSubType(id: 'premier_papa', label: 'Premier "papa"'),
      MilestoneSubType(id: 'premier_maman', label: 'Premier "maman"'),
      MilestoneSubType(id: 'autre_parole', label: 'Autre', hasFreeText: true),
    ],
  ),
  MilestoneCategory(
    id: 'mouvement',
    label: 'Premier mouvement',
    emoji: '🏃',
    isLegacy: true,
    subTypes: [
      MilestoneSubType(id: 'retourne', label: '1ère fois retourné(e)'),
      MilestoneSubType(id: 'assis', label: 'Assis(e)'),
      MilestoneSubType(id: 'sur_genoux', label: 'Sur les genoux'),
      MilestoneSubType(id: 'debout', label: 'Debout'),
      MilestoneSubType(id: 'rampe', label: 'Avancé en rampant'),
      MilestoneSubType(id: 'quatre_pattes', label: 'Avancé sur les genoux'),
      MilestoneSubType(id: 'marche', label: 'Avancé debout'),
    ],
  ),
  MilestoneCategory(
    id: 'taille_poids',
    label: 'Taille & Poids',
    emoji: '📊',
    isLegacy: true,
  ),
  MilestoneCategory(
    id: 'anecdote',
    label: 'Anecdote',
    emoji: '📖',
    isLegacy: true,
  ),
];

// ── Catégories spécifiques aux carnets « Grossesse » ─────────────────────────
// Liste séparée de [kMilestoneCategories] (jalons enfant) pour que les écrans
// de jalons bébé (add/scan/timeline) ne montrent jamais ces étapes-là.
const List<MilestoneCategory> kPregnancyCategories = [
  MilestoneCategory(
    id: 'annonce',
    label: 'Annonce',
    emoji: '🤰',
    description: 'L\'annonce de la grossesse',
  ),
  MilestoneCategory(
    id: 'echographie',
    label: 'Échographie',
    emoji: '👶',
    description: 'Première image de bébé',
  ),
  MilestoneCategory(
    id: 'premiers_coups',
    label: 'Premiers coups de pied',
    emoji: '🦶',
    description: 'Bébé bouge',
  ),
  MilestoneCategory(
    id: 'envies',
    label: 'Envies & aversions',
    emoji: '🍫',
    description: 'Fringales et dégoûts',
  ),
  MilestoneCategory(
    id: 'symptomes',
    label: 'Sensations & symptômes',
    emoji: '🤢',
    description: 'Le corps qui change',
  ),
  MilestoneCategory(
    id: 'rdv_medical',
    label: 'Rendez-vous médical',
    emoji: '🩺',
    description: 'Suivi de la grossesse',
  ),
  MilestoneCategory(
    id: 'preparatifs',
    label: 'Préparatifs bébé',
    emoji: '🛏️',
    description: 'Chambre, valise, achats',
  ),
  MilestoneCategory(
    id: 'prenom',
    label: 'Choix du prénom',
    emoji: '🔤',
    description: 'Le prénom de bébé',
  ),
  MilestoneCategory(
    id: 'humeurs',
    label: 'Émotions & humeurs',
    emoji: '💗',
    description: 'Joies, doutes, espoirs',
  ),
  MilestoneCategory(
    id: 'accouchement',
    label: 'Accouchement',
    emoji: '🏥',
    description: 'Le grand jour',
  ),
];

/// Catégories proposées dans le choix manuel du type de souvenir, selon le type
/// de carnet :
/// - « enfant » : jalons développementaux du bébé ;
/// - « grossesse » : étapes de la grossesse ;
/// - autres (famille, voyage, moi, libre) : aucune liste → l'utilisateur écrit
///   librement (l'IA classe, sinon le formulaire « anecdote »). Pas de grille.
List<MilestoneCategory> manualCategoriesForNotebook(String notebookType) {
  switch (notebookType) {
    case 'enfant':
      return kMilestoneCategories.where((c) => !c.isLegacy).toList();
    case 'grossesse':
      return kPregnancyCategories;
    default:
      return const [];
  }
}

MilestoneCategory getMilestoneCategoryById(String id) =>
    [...kMilestoneCategories, ...kPregnancyCategories].firstWhere(
      (c) => c.id == id,
      orElse: () => kMilestoneCategories.last,
    );

MilestoneSubType? getMilestoneSubTypeById(String categoryId, String subTypeId) {
  final cat = getMilestoneCategoryById(categoryId);
  try {
    return cat.subTypes.firstWhere((s) => s.id == subTypeId);
  } catch (_) {
    return null;
  }
}

// Retourne la position d'une catégorie dans l'ordre développemental (0-based).
// Les catégories legacy ou inconnues sont placées à la fin.
int getMilestoneCategoryOrder(String typeId) {
  final idx = kMilestoneCategories.indexWhere((c) => c.id == typeId);
  return idx == -1 ? 999 : idx;
}
