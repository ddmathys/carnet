import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MigrationService {
  static const _migrationKey = 'bloom_migration_v2_done';

  static Future<void> runIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationKey) == true) {
      // Safety check: if flag is set but notebooks empty, redo migration.
      // Wrapped in try/catch — PERMISSION_DENIED on legacy collections is non-fatal.
      try {
        final firestore = FirebaseFirestore.instance;
        final check = await firestore.collection('notebooks').limit(1).get();
        final hasChildren =
            await firestore.collection('children').limit(1).get();
        if (check.docs.isEmpty && hasChildren.docs.isNotEmpty) {
          await prefs.remove(_migrationKey);
        } else {
          return;
        }
      } catch (_) {
        // Can't verify — assume migration is done and continue.
        return;
      }
    }

    try {
      await _migrateChildrenToNotebooks();
      await _migrateMilestonesToMemories();
      await prefs.setBool(_migrationKey, true);
    } catch (e) {
      // Silent fail — existing data remains untouched, retry next launch
    }
  }

  static Future<void> _migrateChildrenToNotebooks() async {
    final firestore = FirebaseFirestore.instance;
    final children = await firestore.collection('children').get();
    if (children.docs.isEmpty) return;

    final batch = firestore.batch();
    for (final doc in children.docs) {
      final data = Map<String, dynamic>.from(doc.data());
      // Map old fields to new schema
      final notebook = <String, dynamic>{
        'type': 'enfant',
        'userId': data['parentId'] ?? '',
        'title': data['firstName'] ?? '',
        'coverColor': data['coverColor'] ?? '#7A9E7E',
        'companion': data['animalId'],
        'companionName': data['animalName'],
        if (data['birthDate'] != null) 'birthdate': data['birthDate'],
        'gender': data['gender'],
        'memoriesCount': 0,
        'createdAt': data['createdAt'] ?? FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      // Write to notebooks collection with same document ID
      batch.set(firestore.collection('notebooks').doc(doc.id), notebook);
    }
    await batch.commit();
  }

  static Future<void> _migrateMilestonesToMemories() async {
    final firestore = FirebaseFirestore.instance;
    final milestones = await firestore.collection('milestones').get();
    if (milestones.docs.isEmpty) return;

    // Process in batches of 500 (Firestore limit)
    const batchSize = 400;
    for (var i = 0; i < milestones.docs.length; i += batchSize) {
      final chunk = milestones.docs.skip(i).take(batchSize).toList();
      final batch = firestore.batch();
      for (final doc in chunk) {
        final data = Map<String, dynamic>.from(doc.data());
        final memory = <String, dynamic>{
          ...data,
          'notebookId': data['childId'] ?? '',
          'mediaUrls': data['mediaUrls'] ?? [],
        };
        // Keep childId for backward compat with existing screens during transition
        batch.set(firestore.collection('memories').doc(doc.id), memory);
      }
      await batch.commit();
    }

    // Update memoriesCount on each notebook
    final notebooks = await firestore.collection('notebooks').get();
    for (final nb in notebooks.docs) {
      final countSnap = await firestore
          .collection('memories')
          .where('notebookId', isEqualTo: nb.id)
          .get();
      final sorted = countSnap.docs
        ..sort((a, b) {
          final aDate = (a.data()['date'] as Timestamp?)?.toDate();
          final bDate = (b.data()['date'] as Timestamp?)?.toDate();
          if (aDate == null) return 1;
          if (bDate == null) return -1;
          return bDate.compareTo(aDate);
        });
      final update = <String, dynamic>{
        'memoriesCount': countSnap.docs.length,
        if (sorted.isNotEmpty)
          'lastMemoryAt': sorted.first.data()['date'],
      };
      await nb.reference.update(update);
    }
  }

  // Reset for development/testing
  static Future<void> resetMigrationFlag() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_migrationKey);
  }
}
