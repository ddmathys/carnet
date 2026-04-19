class MilestoneType {
  final String id;
  final String label;
  final String emoji;

  const MilestoneType({
    required this.id,
    required this.label,
    required this.emoji,
  });
}

const List<MilestoneType> kMilestoneTypes = [
  MilestoneType(id: 'first_word', label: 'Premier mot', emoji: '💬'),
  MilestoneType(id: 'first_step', label: 'Premiers pas', emoji: '👣'),
  MilestoneType(id: 'weight', label: 'Poids', emoji: '⚖️'),
  MilestoneType(id: 'height', label: 'Taille', emoji: '📏'),
  MilestoneType(id: 'photo', label: 'Photo souvenir', emoji: '📷'),
  MilestoneType(id: 'note', label: 'Anecdote', emoji: '📝'),
  MilestoneType(id: 'custom', label: 'Autre moment', emoji: '✨'),
];

MilestoneType getMilestoneTypeById(String id) =>
    kMilestoneTypes.firstWhere((t) => t.id == id, orElse: () => kMilestoneTypes.last);
