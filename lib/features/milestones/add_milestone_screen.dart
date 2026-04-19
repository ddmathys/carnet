import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'dart:io';
import '../../core/theme/app_theme.dart';
import '../../core/constants/milestone_types.dart';

class AddMilestoneScreen extends StatefulWidget {
  final String childId;
  const AddMilestoneScreen({super.key, required this.childId});

  @override
  State<AddMilestoneScreen> createState() => _AddMilestoneScreenState();
}

class _AddMilestoneScreenState extends State<AddMilestoneScreen> {
  final _contentController = TextEditingController();
  String _selectedType = 'note';
  DateTime _selectedDate = DateTime.now();
  File? _photo;
  bool _loading = false;

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final xFile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (xFile != null) setState(() => _photo = File(xFile.path));
  }

  Future<String?> _uploadPhoto() async {
    if (_photo == null) return null;
    final ref = FirebaseStorage.instance
        .ref('milestones/${widget.childId}/${DateTime.now().millisecondsSinceEpoch}.jpg');
    await ref.putFile(_photo!);
    return await ref.getDownloadURL();
  }

  Future<void> _save() async {
    if (_contentController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Décris ce moment spécial')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final photoUrl = await _uploadPhoto();
      await FirebaseFirestore.instance.collection('milestones').add({
        'childId': widget.childId,
        'type': _selectedType,
        'date': Timestamp.fromDate(_selectedDate),
        'rawContent': _contentController.text.trim(),
        'aiNarration': null,
        'photoUrl': photoUrl,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) context.go('/child/${widget.childId}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Erreur lors de la sauvegarde')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nouveau souvenir'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/child/${widget.childId}'),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Quel type de moment ?',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textDark,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: kMilestoneTypes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final type = kMilestoneTypes[i];
                  final selected = _selectedType == type.id;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedType = type.id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.sage : AppColors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: selected ? AppColors.sage : AppColors.beige,
                        ),
                      ),
                      child: Text(
                        '${type.emoji} ${type.label}',
                        style: TextStyle(
                          color: selected ? AppColors.white : AppColors.textMedium,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _pickDate,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.beige, width: 1.5),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_outlined,
                        color: AppColors.textMedium, size: 18),
                    const SizedBox(width: 10),
                    Text(
                      DateFormat('d MMMM yyyy', 'fr').format(_selectedDate),
                      style: const TextStyle(color: AppColors.textDark),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _contentController,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Décris ce moment...',
                hintText: 'Ce matin, il a dit "papa" pour la première fois...',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _pickPhoto,
              child: Container(
                height: _photo != null ? 160 : 80,
                decoration: BoxDecoration(
                  color: AppColors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppColors.beige,
                    width: 1.5,
                    style: BorderStyle.solid,
                  ),
                ),
                child: _photo != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.file(_photo!, fit: BoxFit.cover,
                            width: double.infinity),
                      )
                    : const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_photo_alternate_outlined,
                                color: AppColors.softGray, size: 28),
                            SizedBox(height: 4),
                            Text('Ajouter une photo (optionnel)',
                                style: TextStyle(
                                    color: AppColors.softGray, fontSize: 13)),
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 28),
            _loading
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton(
                    onPressed: _save,
                    child: const Text('Enregistrer ce souvenir'),
                  ),
          ],
        ),
      ),
    );
  }
}
