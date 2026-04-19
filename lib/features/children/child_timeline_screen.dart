import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/animals.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/models/child_model.dart';
import '../../core/models/milestone_model.dart';

class ChildTimelineScreen extends StatelessWidget {
  final String childId;
  const ChildTimelineScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('children').doc(childId).get(),
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
          ),
          body: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('milestones')
                .where('childId', isEqualTo: childId)
                .orderBy('date', descending: true)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return _EmptyTimeline(childName: child.firstName);
              }
              final milestones =
                  docs.map((d) => MilestoneModel.fromFirestore(d)).toList();
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
                itemCount: milestones.length,
                itemBuilder: (_, i) => _MilestoneCard(milestone: milestones[i]),
              );
            },
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => context.go('/child/$childId/add-milestone'),
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
            Text(
              'Aucun souvenir encore',
              style: const TextStyle(
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

class _MilestoneCard extends StatelessWidget {
  final MilestoneModel milestone;
  const _MilestoneCard({required this.milestone});

  @override
  Widget build(BuildContext context) {
    final type = getMilestoneTypeById(milestone.type);
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
              Text(type.emoji, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Text(
                type.label,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.sage,
                ),
              ),
              const Spacer(),
              Text(
                DateFormat('d MMM yyyy', 'fr').format(milestone.date),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.softGray,
                ),
              ),
            ],
          ),
          if (milestone.photoUrl != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                milestone.photoUrl!,
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (milestone.aiNarration != null) ...[
            Text(
              milestone.aiNarration!,
              style: const TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 15,
                color: AppColors.textDark,
                height: 1.6,
                fontStyle: FontStyle.italic,
              ),
            ),
          ] else ...[
            Text(
              milestone.rawContent,
              style: const TextStyle(
                color: AppColors.textMedium,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
