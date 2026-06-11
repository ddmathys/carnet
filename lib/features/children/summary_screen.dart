import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/child_model.dart';
import '../../core/models/milestone_model.dart';
import '../../core/utils/date_precision.dart';
import '../../core/constants/milestone_types.dart';

class SummaryScreen extends StatelessWidget {
  final String childId;
  const SummaryScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('children').doc(childId).get(),
      builder: (context, childSnap) {
        if (!childSnap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final child = ChildModel.fromFirestore(childSnap.data!);

        return Scaffold(
          backgroundColor: AppColors.cream,
          appBar: AppBar(
            backgroundColor: AppColors.cream,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.go('/home'),
            ),
            title: Text(child.firstName,
                style: const TextStyle(fontFamily: 'PlayfairDisplay', fontWeight: FontWeight.bold)),
            actions: [
              IconButton(
                icon: const Icon(Icons.show_chart),
                color: AppColors.sage,
                tooltip: 'Croissance',
                onPressed: () => context.push('/child/$childId/growth'),
              ),
              IconButton(
                icon: const Icon(Icons.menu_book_outlined),
                color: AppColors.sage,
                tooltip: 'Journal',
                onPressed: () => context.push('/child/$childId/journal'),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => context.push('/child/$childId/add-milestone'),
            backgroundColor: AppColors.sage,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add),
            label: const Text('Nouveau souvenir'),
          ),
          body: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('milestones')
                .where('childId', isEqualTo: childId)
                .snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final all = snap.data!.docs
                  .map((d) => MilestoneModel.fromFirestore(d))
                  .toList()
                ..sort((a, b) => b.date.compareTo(a.date));

              final measurements = all
                  .where((m) => m.type == 'taille_poids')
                  .toList();

              final anecdotes = all.where((m) => m.type == 'anecdote').toList()
                ..sort((a, b) => b.date.compareTo(a.date));

              final MilestoneModel? latestWeight = measurements
                  .cast<MilestoneModel?>()
                  .firstWhere((m) => m?.weightKg != null, orElse: () => null);

              final MilestoneModel? latestHeight = measurements
                  .cast<MilestoneModel?>()
                  .firstWhere((m) => m?.heightCm != null, orElse: () => null);

              final MilestoneModel? latestAnecdote =
                  anecdotes.isEmpty ? null : anecdotes.first;
              final MilestoneModel? latestEntry = all.isEmpty ? null : all.first;

              final typeBreakdown = <String, int>{};
              for (final m in all) {
                typeBreakdown[m.type] = (typeBreakdown[m.type] ?? 0) + 1;
              }

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HeaderCard(child: child),
                    const SizedBox(height: 16),
                    // Quick-action buttons
                    _QuickActions(childId: childId),
                    const SizedBox(height: 16),
                    _StatsRow(
                      total: all.length,
                      measurements: measurements.length,
                      anecdotes: anecdotes.length,
                    ),
                    const SizedBox(height: 16),
                    if (latestEntry != null) ...[
                      _InfoCard(
                        icon: Icons.access_time_rounded,
                        color: AppColors.sage,
                        title: 'Dernière saisie',
                        value: _formatDate(latestEntry),
                        subtitle: _typeLabel(latestEntry.type),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (latestHeight != null) ...[
                      _InfoCard(
                        icon: Icons.height,
                        color: const Color(0xFF7A9EC8),
                        title: 'Dernière taille',
                        value: '${latestHeight.heightCm!.toStringAsFixed(0)} cm',
                        subtitle: _formatDate(latestHeight),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (latestWeight != null) ...[
                      _InfoCard(
                        icon: Icons.monitor_weight_outlined,
                        color: const Color(0xFFD4956A),
                        title: 'Dernier poids',
                        value: '${latestWeight.weightKg!.toStringAsFixed(1)} kg',
                        subtitle: _formatDate(latestWeight),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (latestAnecdote != null) ...[
                      _AnecdoteCard(milestone: latestAnecdote),
                      const SizedBox(height: 10),
                    ],
                    if (typeBreakdown.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _BreakdownCard(breakdown: typeBreakdown),
                    ],
                    const SizedBox(height: 20),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  String _formatDate(MilestoneModel m) =>
      m.dateLabel ??
      formatDateWithPrecision(m.date, datePrecisionFromString(m.datePrecision));

  String _typeLabel(String type) {
    try {
      return getMilestoneCategoryById(type).label;
    } catch (_) {
      return type;
    }
  }
}

class _QuickActions extends StatelessWidget {
  final String childId;
  const _QuickActions({required this.childId});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ActionBtn(
          icon: Icons.menu_book_outlined,
          label: 'Journal',
          color: const Color(0xFFB07AB8),
          onTap: () => context.push('/child/$childId/journal'),
        ),
        const SizedBox(width: 10),
        _ActionBtn(
          icon: Icons.show_chart,
          label: 'Croissance',
          color: AppColors.sage,
          onTap: () => context.push('/child/$childId/growth'),
        ),
        const SizedBox(width: 10),
        _ActionBtn(
          icon: Icons.auto_stories_outlined,
          label: 'Histoire',
          color: const Color(0xFFD4956A),
          onTap: () => context.push('/child/$childId/story'),
        ),
      ],
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                    fontSize: 11, color: color, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final ChildModel child;
  const _HeaderCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.sage.withOpacity(0.18),
            AppColors.sage.withOpacity(0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.sage.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                child.firstName,
                style: const TextStyle(
                  fontFamily: 'PlayfairDisplay',
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                child.age,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              ),
            ],
          ),
          const Spacer(),
          Text(
            child.gender == 'boy' ? '👦' : '👧',
            style: const TextStyle(fontSize: 40),
          ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final int total;
  final int measurements;
  final int anecdotes;
  const _StatsRow(
      {required this.total, required this.measurements, required this.anecdotes});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _StatChip(value: total, label: 'Total', color: AppColors.sage),
        const SizedBox(width: 10),
        _StatChip(
            value: measurements,
            label: 'Mesures',
            color: const Color(0xFF7A9EC8)),
        const SizedBox(width: 10),
        _StatChip(
            value: anecdotes,
            label: 'Anecdotes',
            color: const Color(0xFFD4956A)),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final int value;
  final String label;
  final Color color;
  const _StatChip(
      {required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            Text(
              '$value',
              style: TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w800, color: color),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color.withOpacity(0.8)),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String value;
  final String subtitle;

  const _InfoCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textDark),
                ),
              ],
            ),
          ),
          Text(subtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
        ],
      ),
    );
  }
}

class _AnecdoteCard extends StatelessWidget {
  final MilestoneModel milestone;
  const _AnecdoteCard({required this.milestone});

  @override
  Widget build(BuildContext context) {
    final content = milestone.aiNarration?.isNotEmpty == true
        ? milestone.aiNarration!
        : milestone.rawContent;
    final preview =
        content.length > 160 ? '${content.substring(0, 160)}…' : content;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F0E8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8DECC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('📖', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              const Text(
                'Dernière anecdote',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.textDark),
              ),
              const Spacer(),
              Text(
                milestone.dateLabel ??
                    formatDateWithPrecision(milestone.date,
                        datePrecisionFromString(milestone.datePrecision)),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            preview,
            style: TextStyle(
                fontSize: 13, color: Colors.grey.shade700, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _BreakdownCard extends StatelessWidget {
  final Map<String, int> breakdown;
  const _BreakdownCard({required this.breakdown});

  @override
  Widget build(BuildContext context) {
    final total = breakdown.values.fold(0, (a, b) => a + b);
    final entries = breakdown.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Répartition des souvenirs',
            style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: AppColors.textDark),
          ),
          const SizedBox(height: 14),
          ...entries.map((e) {
            final cat = _categoryInfo(e.key);
            final pct = total > 0 ? e.value / total : 0.0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('${cat.$1} ${cat.$2}',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textDark)),
                      const Spacer(),
                      Text('${e.value}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade600)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 6,
                      backgroundColor: Colors.grey.shade100,
                      valueColor: AlwaysStoppedAnimation<Color>(cat.$3),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  (String, String, Color) _categoryInfo(String type) {
    switch (type) {
      case 'taille_poids':
        return ('📊', 'Taille & Poids', const Color(0xFF7A9EC8));
      case 'anecdote':
        return ('📖', 'Anecdote', const Color(0xFFD4956A));
      case 'parole':
        return ('💬', 'Première parole', const Color(0xFFB07AB8));
      case 'mouvement':
        return ('🏃', 'Premier mouvement', AppColors.sage);
      default:
        return ('✨', type, Colors.grey);
    }
  }
}
