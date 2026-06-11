class Animal {
  final String id;
  final String emoji;
  final String name;
  final String defaultCompanionName;
  final String storyTraits;
  final bool isPremium;

  const Animal({
    required this.id,
    required this.emoji,
    required this.name,
    required this.defaultCompanionName,
    required this.storyTraits,
    this.isPremium = false,
  });
}

const List<Animal> kAnimals = [
  Animal(
    id: 'fox',
    emoji: '🦊',
    name: 'Renard',
    defaultCompanionName: 'Roux',
    storyTraits: 'curieux, malicieux, vif et espiègle',
  ),
  Animal(
    id: 'rabbit',
    emoji: '🐰',
    name: 'Lapin',
    defaultCompanionName: 'Noisette',
    storyTraits: 'doux, timide, bondissant et tendre',
  ),
  Animal(
    id: 'bear',
    emoji: '🐻',
    name: 'Ours',
    defaultCompanionName: 'Balou',
    storyTraits: 'chaleureux, protecteur, grand et câlin',
  ),
  Animal(
    id: 'dino',
    emoji: '🦕',
    name: 'Dinosaure',
    defaultCompanionName: 'Dino',
    storyTraits: 'aventurier, unique, plein d\'énergie et de découvertes',
  ),
  Animal(
    id: 'penguin',
    emoji: '🐧',
    name: 'Pingouin',
    defaultCompanionName: 'Bleu',
    storyTraits: 'élégant, fidèle, drôle et maladroit mais attachant',
  ),
  Animal(
    id: 'mouse',
    emoji: '🐭',
    name: 'Souris',
    defaultCompanionName: 'Mimi',
    storyTraits: 'petit mais courageux, curieux et toujours en mouvement',
  ),
  Animal(
    id: 'cat',
    emoji: '🐱',
    name: 'Chat',
    defaultCompanionName: 'Minou',
    storyTraits: 'indépendant, curieux, agile et infiniment affectueux',
  ),
  Animal(
    id: 'dog',
    emoji: '🐶',
    name: 'Chien',
    defaultCompanionName: 'Filou',
    storyTraits: 'loyal, joyeux, joueur et toujours présent',
  ),
  Animal(
    id: 'tiger',
    emoji: '🐯',
    name: 'Tigre',
    defaultCompanionName: 'Raja',
    storyTraits: 'courageux, puissant, sauvage et tendre à la fois',
  ),
  Animal(
    id: 'giraffe',
    emoji: '🦒',
    name: 'Girafe',
    defaultCompanionName: 'Nala',
    storyTraits: 'élancée, douce, observatrice et majestueuse',
  ),
  Animal(
    id: 'crocodile',
    emoji: '🐊',
    name: 'Crocodile',
    defaultCompanionName: 'Croco',
    storyTraits: 'patient, fort, ancien et sage, protecteur féroce',
  ),
];

Animal getAnimalById(String id) =>
    kAnimals.firstWhere((a) => a.id == id, orElse: () => kAnimals.first);
