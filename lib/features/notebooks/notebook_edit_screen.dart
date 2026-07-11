import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:uuid/uuid.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/notebook_types.dart';
import '../../core/constants/animals.dart';
import '../../core/models/notebook_model.dart';
import '../../core/services/photo_service.dart';
import '../../core/widgets/date_mask_field.dart';

class NotebookEditScreen extends StatefulWidget {
  final String notebookId;
  const NotebookEditScreen({super.key, required this.notebookId});

  @override
  State<NotebookEditScreen> createState() => _NotebookEditScreenState();
}

class _NotebookEditScreenState extends State<NotebookEditScreen> {
  final _formKey = GlobalKey<FormState>();
  NotebookModel? _notebook;
  bool _loading = true;
  bool _saving = false;

  // Fields
  final _titleController = TextEditingController();
  final _destinationController = TextEditingController();
  final _recipientController = TextEditingController();
  final _companionNameController = TextEditingController();
  String _coverColor = AppColors.coverHexColors[0];
  String _gender = 'boy';
  String _selectedAnimalId = 'fox';
  String _bookFrequency = 'monthly';
  DateTime? _birthdate;
  DateTime? _expectedDate;
  DateTime? _tripStart;
  DateTime? _tripEnd;

  // Cover photo
  String? _existingCoverPhotoUrl;
  File? _newCoverPhoto;
  bool _removedCoverPhoto = false;
  final _picker = ImagePicker();
  final _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadNotebook();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _destinationController.dispose();
    _recipientController.dispose();
    _companionNameController.dispose();
    super.dispose();
  }

  Future<void> _loadNotebook() async {
    final doc = await FirebaseFirestore.instance
        .collection('notebooks')
        .doc(widget.notebookId)
        .get();
    if (!mounted || !doc.exists) return;
    final nb = NotebookModel.fromFirestore(doc);
    setState(() {
      _notebook = nb;
      _titleController.text = nb.title;
      _coverColor = nb.coverColor;
      _existingCoverPhotoUrl = nb.coverPhotoUrl;
      _gender = nb.gender ?? 'boy';
      _selectedAnimalId = nb.companion ?? 'fox';
      _companionNameController.text = nb.companionName ?? '';
      _bookFrequency = nb.bookFrequency ?? 'monthly';
      _destinationController.text = nb.destination ?? '';
      _recipientController.text = nb.recipient ?? '';
      _birthdate = nb.birthdate;
      _expectedDate = nb.expectedDate;
      _loading = false;
    });
  }

  Future<void> _pickCoverPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AppColors.softGray.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: AppColors.sage),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: AppColors.sage),
              title: const Text('Choisir depuis la galerie'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picked = await _picker.pickImage(
        source: source, imageQuality: 85, maxWidth: 1200);
    if (picked != null && mounted) {
      setState(() {
        _newCoverPhoto = File(picked.path);
        _removedCoverPhoto = false;
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      String? finalCoverPhotoUrl = _existingCoverPhotoUrl;

      // New photo picked → upload it, delete old if any
      if (_newCoverPhoto != null) {
        if (_existingCoverPhotoUrl != null) {
          await PhotoService.deletePhotoByUrl(_existingCoverPhotoUrl);
        }
        final ref = FirebaseStorage.instance
            .ref('covers/${_notebook!.userId}/${const Uuid().v4()}.jpg');
        final task = await ref.putFile(
            _newCoverPhoto!, SettableMetadata(contentType: 'image/jpeg'));
        finalCoverPhotoUrl = await task.ref.getDownloadURL();
      } else if (_removedCoverPhoto) {
        // Photo removed without replacement
        await PhotoService.deletePhotoByUrl(_existingCoverPhotoUrl);
        finalCoverPhotoUrl = null;
      }

      final nb = _notebook!;
      final notebookType = getNotebookTypeById(nb.type);
      final data = <String, dynamic>{
        'title': _titleController.text.trim(),
        'coverColor': _coverColor,
        'coverPhotoUrl': finalCoverPhotoUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (notebookType.hasGender) data['gender'] = _gender;
      if (notebookType.hasBirthdate && _birthdate != null) {
        data['birthdate'] = Timestamp.fromDate(_birthdate!);
      }
      if (notebookType.hasCompanion) {
        data['companion'] = _selectedAnimalId;
        data['companionName'] = _companionNameController.text.trim();
      }
      if (notebookType.hasDestination) {
        data['destination'] = _destinationController.text.trim();
        if (_tripStart != null) data['tripStart'] = Timestamp.fromDate(_tripStart!);
        if (_tripEnd != null) data['tripEnd'] = Timestamp.fromDate(_tripEnd!);
      }
      if (notebookType.hasRecipient) {
        data['recipient'] = _recipientController.text.trim();
        data['bookFrequency'] = _bookFrequency;
      }
      if (notebookType.hasExpectedDate && _expectedDate != null) {
        data['expectedDate'] = Timestamp.fromDate(_expectedDate!);
      }

      await FirebaseFirestore.instance
          .collection('notebooks')
          .doc(widget.notebookId)
          .update(data);

      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final nb = _notebook!;
    final notebookType = getNotebookTypeById(nb.type);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Modifier le carnet',
          style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () => context.pop(),
        ),
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Title ──
              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: nb.type == 'enfant'
                      ? 'Prénom de l\'enfant'
                      : 'Titre du carnet',
                ),
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    v == null || v.isEmpty ? 'Champ requis' : null,
              ),
              const SizedBox(height: 20),

              // ── Cover photo ──
              _buildCoverPhotoPicker(),
              const SizedBox(height: 20),

              // ── Gender ──
              if (notebookType.hasGender) ...[
                _buildGenderSelector(optional: notebookType.hasExpectedDate),
              ],

              // ── Birthdate ──
              if (notebookType.hasBirthdate && !notebookType.hasExpectedDate) ...[
                DateMaskField(
                  label: 'Date de naissance',
                  initialDate: _birthdate,
                  lastDate: _now,
                  firstDate: DateTime(2000),
                  onChanged: (d) => setState(() => _birthdate = d),
                ),
                const SizedBox(height: 16),
              ],

              // ── Companion ──
              if (notebookType.hasCompanion) ...[
                const Text(
                  'Compagnon animal',
                  style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textDark),
                ),
                const SizedBox(height: 10),
                _buildAnimalChips(),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _companionNameController,
                  decoration: const InputDecoration(labelText: 'Nom du compagnon'),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Champ requis' : null,
                ),
                const SizedBox(height: 16),
              ],

              // ── Destination ──
              if (notebookType.hasDestination) ...[
                TextFormField(
                  controller: _destinationController,
                  decoration: const InputDecoration(labelText: 'Destination'),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DateMaskField(
                        label: 'Départ',
                        initialDate: _tripStart,
                        onChanged: (d) => setState(() => _tripStart = d),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DateMaskField(
                        label: 'Retour',
                        initialDate: _tripEnd,
                        onChanged: (d) => setState(() => _tripEnd = d),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              // ── Recipient + frequency ──
              if (notebookType.hasRecipient) ...[
                TextFormField(
                  controller: _recipientController,
                  decoration: const InputDecoration(
                      labelText: 'Nom du destinataire'),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Fréquence du livre',
                  style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textDark),
                ),
                const SizedBox(height: 10),
                _buildFrequencyChips(),
                const SizedBox(height: 16),
              ],

              // ── Expected date ──
              if (notebookType.hasExpectedDate) ...[
                DateMaskField(
                  label: 'Date d\'accouchement prévue',
                  initialDate: _expectedDate,
                  firstDate: DateTime.now().subtract(const Duration(days: 30)),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                  onChanged: (d) => setState(() => _expectedDate = d),
                ),
                const SizedBox(height: 16),
              ],

              // ── Cover color ──
              const Text(
                'Couleur de couverture',
                style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textDark),
              ),
              const SizedBox(height: 12),
              _buildColorPicker(),
              const SizedBox(height: 32),

              _saving
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      onPressed: _save,
                      child: const Text('Enregistrer les modifications'),
                    ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverPhotoPicker() {
    final hasNew = _newCoverPhoto != null;
    final hasExisting = _existingCoverPhotoUrl != null && !_removedCoverPhoto;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Photo de couverture',
          style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textDark),
        ),
        const SizedBox(height: 10),
        if (hasNew || hasExisting) ...[
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: hasNew
                    ? Image.file(
                        _newCoverPhoto!,
                        width: double.infinity,
                        height: 160,
                        fit: BoxFit.cover,
                      )
                    : CachedNetworkImage(
                        imageUrl: _existingCoverPhotoUrl!,
                        width: double.infinity,
                        height: 160,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(
                          height: 160,
                          color: AppColors.background,
                          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: () => setState(() {
                    _newCoverPhoto = null;
                    _removedCoverPhoto = true;
                  }),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, color: Colors.white, size: 16),
                  ),
                ),
              ),
              Positioned(
                bottom: 8,
                right: 8,
                child: GestureDetector(
                  onTap: _pickCoverPhoto,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_outlined, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text('Changer', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ] else ...[
          GestureDetector(
            onTap: _pickCoverPhoto,
            child: Container(
              width: double.infinity,
              height: 120,
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border, width: 0.5),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.sage.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.add_a_photo_outlined, color: AppColors.sage, size: 22),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Ajouter une photo',
                    style: TextStyle(color: AppColors.sage, fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Optionnel · galerie ou appareil',
                    style: TextStyle(color: AppColors.softGray, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildGenderSelector({bool optional = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          optional ? 'Sexe (optionnel)' : 'Genre',
          style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.textDark),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _GenderChip(
                emoji: '👦',
                label: 'Garçon',
                selected: _gender == 'boy',
                onTap: () => setState(() => _gender = 'boy'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _GenderChip(
                emoji: '👧',
                label: 'Fille',
                selected: _gender == 'girl',
                onTap: () => setState(() => _gender = 'girl'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildAnimalChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: kAnimals.map((animal) {
        final selected = _selectedAnimalId == animal.id;
        return GestureDetector(
          onTap: () => setState(() {
            _selectedAnimalId = animal.id;
            _companionNameController.text = animal.defaultCompanionName;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? AppColors.sage.withOpacity(0.15) : AppColors.white,
              borderRadius: BorderRadius.circular(50),
              border: Border.all(
                color: selected ? AppColors.sage : AppColors.border,
                width: selected ? 1.5 : 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(animal.emoji, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 6),
                Text(
                  animal.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected ? AppColors.sage : AppColors.textDark,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildFrequencyChips() {
    final options = [
      ('monthly', 'Mensuelle'),
      ('quarterly', 'Trimestrielle'),
      ('annual', 'Annuelle'),
    ];
    return Row(
      children: options.map((opt) {
        final selected = _bookFrequency == opt.$1;
        return Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _bookFrequency = opt.$1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: EdgeInsets.only(right: opt.$1 != 'annual' ? 8 : 0),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected ? AppColors.sage.withOpacity(0.12) : AppColors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? AppColors.sage : AppColors.border,
                  width: selected ? 1.5 : 0.5,
                ),
              ),
              child: Text(
                opt.$2,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? AppColors.sage : AppColors.textMedium,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildColorPicker() {
    return Row(
      children: AppColors.coverHexColors.map((hex) {
        final color = Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
        final selected = _coverColor == hex;
        return GestureDetector(
          onTap: () => setState(() => _coverColor = hex),
          child: Container(
            margin: const EdgeInsets.only(right: 12),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? AppColors.textDark : Colors.transparent,
                width: 2.5,
              ),
              boxShadow: selected
                  ? [BoxShadow(color: color.withOpacity(0.4), blurRadius: 8, spreadRadius: 1)]
                  : [],
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _GenderChip extends StatelessWidget {
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _GenderChip({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 70,
        decoration: BoxDecoration(
          color: selected ? AppColors.sage.withOpacity(0.12) : AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.sage : AppColors.border,
            width: selected ? 2 : 0.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: selected ? AppColors.sage : AppColors.textDark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
