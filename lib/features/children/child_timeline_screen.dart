import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/animals.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/models/child_model.dart';
import '../../core/models/milestone_model.dart';
import '../../core/utils/date_precision.dart';

class ChildTimelineScreen extends StatefulWidget {
  final String childId;
  const ChildTimelineScreen({super.key, required this.childId});

  @override
  State<ChildTimelineScreen> createState() => _ChildTimelineScreenState();
}

class _ChildTimelineScreenState extends State<ChildTimelineScreen> {
  String? _typeFilter;   // null = tous
  int? _yearFilter;      // null = toutes années

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance
          .collection('children')
          .doc(widget.childId)
          .get(),
      builder: (context, childSnap) {
        if (!childSnap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final child = ChildModel.fromFirestore(childSnap.data!);
        final animal = getAnimalById(child.animalId);

        return Scaffold(
          appBar: AppBar(
            title: Text('${child.firstName} ${animal.emoji}'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.go('/home'),
            ),
            actions: [
              IconButton(
                onPressed: () =>
                    context.push('/child/${widget.childId}/growth'),
                icon: const Icon(Icons.show_chart),
                color: AppColors.sage,
                tooltip: 'Croissance',
              ),
              IconButton(
                onPressed: () =>
                    context.push('/child/${widget.childId}/summary'),
                icon: const Icon(Icons.bar_chart_rounded),
                color: AppColors.sage,
                tooltip: 'Résumé',
              ),
              TextButton.icon(
                onPressed: () => context.push('/child/${widget.childId}/story'),
                icon: const Text('📖', style: TextStyle(fontSize: 16)),
                label: const Text(
                  'Histoire',
                  style: TextStyle(
                    color: AppColors.sage,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          body: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('milestones')
                .where('childId', isEqualTo: widget.childId)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text('Erreur : ${snap.error}',
                      style: const TextStyle(color: AppColors.error)),
                );
              }
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final allMilestones = (snap.data?.docs ?? [])
                  .map((d) => MilestoneModel.fromFirestore(d))
                  .toList()
                ..sort((a, b) => b.date.compareTo(a.date));

              // Années disponibles pour le filtre
              final availableYears = allMilestones
                  .map((m) => m.date.year)
                  .toSet()
                  .toList()
                ..sort((a, b) => b.compareTo(a));

              // Application des filtres
              final filtered = allMilestones.where((m) {
                if (_typeFilter != null && m.type != _typeFilter) return false;
                if (_yearFilter != null && m.date.year != _yearFilter) return false;
                return true;
              }).toList();

              return Column(
                children: [
                  _FilterBar(
                    selectedType: _typeFilter,
                    selectedYear: _yearFilter,
                    availableYears: availableYears,
                    onTypeChanged: (t) => setState(() => _typeFilter = t),
                    onYearChanged: (y) => setState(() => _yearFilter = y),
                  ),
                  Expanded(
                    child: allMilestones.isEmpty
                        ? _EmptyTimeline(childName: child.firstName)
                        : filtered.isEmpty
                            ? _EmptyFilter(
                                onReset: () => setState(() {
                                  _typeFilter = null;
                                  _yearFilter = null;
                                }),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
                                itemCount: filtered.length,
                                itemBuilder: (_, i) => _MilestoneCard(
                                      milestone: filtered[i],
                                      childId: widget.childId,
                                    ),
                              ),
                  ),
                ],
              );
            },
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => context.push('/child/${widget.childId}/add-milestone'),
            backgroundColor: AppColors.sage,
            foregroundColor: AppColors.white,
            icon: const Icon(Icons.add),
            label: const Text('Nouveau souvenir'),
          ),
        );
      },
    );
  }
}

// ── Barre de filtres ──────────────────────────────────────────────────────

class _FilterBar extends StatelessWidget {
  final String? selectedType;
  final int? selectedYear;
  final List<int> availableYears;
  final ValueChanged<String?> onTypeChanged;
  final ValueChanged<int?> onYearChanged;

  const _FilterBar({
    required this.selectedType,
    required this.selectedYear,
    required this.availableYears,
    required this.onTypeChanged,
    required this.onYearChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hasActiveFilter = selectedType != null || selectedYear != null;

    return Container(
      color: AppColors.cream,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Filtre type
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _TypeChip(
                  label: 'Tous',
                  emoji: null,
                  selected: selectedType == null,
                  onTap: () => onTypeChanged(null),
                ),
                const SizedBox(width: 6),
                ...kMilestoneCategories.map((cat) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _TypeChip(
                        label: cat.label,
                        emoji: cat.emoji,
                        selected: selectedType == cat.id,
                        onTap: () => onTypeChanged(
                          selectedType == cat.id ? null : cat.id,
                        ),
                      ),
                    )),
              ],
            ),
          ),
          if (availableYears.isNotEmpty) ...[
            const SizedBox(height: 8),
            // Filtre année
            SizedBox(
              height: 32,
              child: Row(
                children: [
                  const Icon(Icons.calendar_month_outlined,
                      size: 15, color: AppColors.softGray),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _YearChip(
                          label: 'Toutes',
                          selected: selectedYear == null,
                          onTap: () => onYearChanged(null),
                        ),
                        const SizedBox(width: 6),
                        ...availableYears.map((y) => Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: _YearChip(
                                label: '$y',
                                selected: selectedYear == y,
                                onTap: () => onYearChanged(
                                  selectedYear == y ? null : y,
                                ),
                              ),
                            )),
                      ],
                    ),
                  ),
                  if (hasActiveFilter)
                    GestureDetector(
                      onTap: () {
                        onTypeChanged(null);
                        onYearChanged(null);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.earth.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Réinitialiser',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.earth,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final String? emoji;
  final bool selected;
  final VoidCallback onTap;

  const _TypeChip({
    required this.label,
    required this.emoji,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.sage : AppColors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? AppColors.sage : AppColors.beige,
          ),
        ),
        child: Text(
          emoji != null ? '$emoji $label' : label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected ? AppColors.white : AppColors.textMedium,
          ),
        ),
      ),
    );
  }
}

class _YearChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _YearChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.earth : AppColors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.earth : AppColors.beige,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected ? AppColors.white : AppColors.textMedium,
          ),
        ),
      ),
    );
  }
}

// ── États vides ──────────────────────────────────────────────────────────

class _EmptyTimeline extends StatelessWidget {
  final String childName;
  const _EmptyTimeline({required this.childName});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📝', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            const Text(
              'Aucun souvenir encore',
              style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Capture le premier moment de $childName.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMedium),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyFilter extends StatelessWidget {
  final VoidCallback onReset;
  const _EmptyFilter({required this.onReset});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔍', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 16),
            const Text(
              'Aucun souvenir\ncorrespond à ce filtre',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark,
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: onReset,
              child: const Text(
                'Voir tous les souvenirs',
                style: TextStyle(color: AppColors.sage),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Carte souvenir ────────────────────────────────────────────────────────

class _MilestoneCard extends StatelessWidget {
  final MilestoneModel milestone;
  final String childId;
  const _MilestoneCard({required this.milestone, required this.childId});

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Supprimer ce souvenir ?',
          style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
        content: const Text(
          'Ce souvenir sera supprimé définitivement.',
          style: TextStyle(color: AppColors.textMedium, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler',
                style: TextStyle(color: AppColors.textMedium)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await FirebaseFirestore.instance
          .collection('milestones')
          .doc(milestone.id)
          .delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final category = getMilestoneCategoryById(milestone.type);
    final subType = milestone.subType != null
        ? getMilestoneSubTypeById(milestone.type, milestone.subType!)
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(category.emoji, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subType != null ? subType.label : category.label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.sage,
                      ),
                    ),
                    Text(
                      milestone.dateLabel ??
                          formatDateWithPrecision(
                            milestone.date,
                            datePrecisionFromString(milestone.datePrecision),
                          ),
                      style: const TextStyle(fontSize: 11, color: AppColors.softGray),
                    ),
                  ],
                ),
              ),
              // Bouton Modifier
              Material(
                color: AppColors.sage.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: () => context.go(
                      '/child/$childId/edit-milestone/${milestone.id}'),
                  borderRadius: BorderRadius.circular(10),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.edit_outlined,
                        size: 18, color: AppColors.sage),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Bouton Supprimer
              Material(
                color: AppColors.error.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: () => _confirmDelete(context),
                  borderRadius: BorderRadius.circular(10),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.delete_outline,
                        size: 18, color: AppColors.error),
                  ),
                ),
              ),
            ],
          ),
          if (milestone.type == 'taille_poids') ...[
            const SizedBox(height: 12),
            _TaillePoidsRow(milestone: milestone),
          ] else if (milestone.rawContent.isNotEmpty) ...[
            const SizedBox(height: 12),
            if (milestone.aiNarration != null)
              Text(
                milestone.aiNarration!,
                style: const TextStyle(
                  fontFamily: 'PlayfairDisplay',
                  fontSize: 15,
                  color: AppColors.textDark,
                  height: 1.6,
                  fontStyle: FontStyle.italic,
                ),
              )
            else
              Text(
                milestone.rawContent,
                style: const TextStyle(color: AppColors.textMedium, height: 1.5),
              ),
          ],
        ],
      ),
    );
  }
}

class _TaillePoidsRow extends StatelessWidget {
  final MilestoneModel milestone;
  const _TaillePoidsRow({required this.milestone});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (milestone.weightKg != null) ...[
          _MetricChip(icon: '⚖️', value: '${milestone.weightKg!.toStringAsFixed(1)} kg'),
          const SizedBox(width: 10),
        ],
        if (milestone.heightCm != null)
          _MetricChip(icon: '📏', value: '${milestone.heightCm!.toStringAsFixed(1)} cm'),
      ],
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String icon;
  final String value;
  const _MetricChip({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.beige,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: AppColors.textDark,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
