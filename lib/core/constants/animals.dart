class Animal {
  final String id;
  final String emoji;
  final String name;
  final String defaultCompanionName;
  final bool isPremium;

  const Animal({
    required this.id,
    required this.emoji,
    required this.name,
    required this.defaultCompanionName,
    this.isPremium = false,
  });
}

const List<Animal> kAnimals = [
  Animal(id: 'fox', emoji: '🦊', name: 'Renard', defaultCompanionName: 'Roux'),
  Animal(id: 'rabbit', emoji: '🐰', name: 'Lapin', defaultCompanionName: 'Noisette'),
  Animal(id: 'bear', emoji: '🐻', name: 'Ours', defaultCompanionName: 'Balou'),
  Animal(id: 'dino', emoji: '🦕', name: 'Dinosaure', defaultCompanionName: 'Dino'),
  Animal(id: 'penguin', emoji: '🐧', name: 'Pingouin', defaultCompanionName: 'Bleu'),
  Animal(id: 'mouse', emoji: '🐭', name: 'Souris', defaultCompanionName: 'Mimi'),
];

Animal getAnimalById(String id) =>
    kAnimals.firstWhere((a) => a.id == id, orElse: () => kAnimals.first);
