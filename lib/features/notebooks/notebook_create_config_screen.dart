import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/notebook_types.dart';
import '../../core/constants/animals.dart';
import '../../core/widgets/date_mask_field.dart';

class NotebookCreateConfigScreen extends StatefulWidget {
  final String type;
  const NotebookCreateConfigScreen({super.key, required this.type});

  @override
  State<NotebookCreateConfigScreen> createState() =>
      _NotebookCreateConfigScreenState();
}

class _NotebookCreateConfigScreenState
    extends State<NotebookCreateConfigScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _companionNameController = TextEditingController();
  final _destinationController = TextEditingController();
  final _recipientController = TextEditingController();

  String _coverColor = AppColors.coverHexColors[0];
  String _gender = 'boy';
  String _selectedAnimalId = 'fox';
  String _bookFrequency = 'monthly';
  DateTime? _birthdate;
  DateTime? _expectedDate;
  DateTime? _tripStart;
  DateTime? _tripEnd;
  bool _loading = false;
  final _now = DateTime.now();
  File? _coverPhoto;
  final _picker = ImagePicker();

  late NotebookType _notebookType;

  @override
  void initState() {
    super.initState();
    _notebookType = getNotebookTypeById(widget.type);
    _companionNameController.text = kAnimals.first.defaultCompanionName;
    // Default title suggestion
    switch (widget.type) {
      case 'voyage':
        _titleController.text = 'Mon voyage';
        break;
      case 'famille':
        _titleController.text = 'Gazette famille';
        break;
      case 'grossesse':
        _titleController.text = 'Ma grossesse';
        break;
      case 'scolaire':
        _titleController.text = 'Années scolaires';
        break;
      case 'libre':
        _titleController.text = 'Mon carnet';
        break;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _companionNameController.dispose();
    _destinationController.dispose();
    _recipientController.dispose();
    super.dispose();
  }


  Future<void> _pickCoverPhoto() async {
    try {
      final sheet = await showModalBottomSheet<ImageSource>(
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
      if (sheet == null) return;
      final picked = await _picker.pickImage(
        source: sheet, imageQuality: 85, maxWidth: 1200,
      );
      if (picked != null && mounted) {
        setState(() => _coverPhoto = File(picked.path));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible d\'accéder à la photo')),
        );
      }
    }
  }

  Future<String?> _uploadCoverPhoto(String uid) async {
    if (_coverPhoto == null) return null;
    final ref = FirebaseStorage.instance
        .ref('covers/$uid/${const Uuid().v4()}.jpg');
    final task = await ref.putFile(
        _coverPhoto!, SettableMetadata(contentType: 'image/jpeg'));
    return await task.ref.getDownloadURL();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;

      final coverPhotoUrl = await _uploadCoverPhoto(uid);

      final data = <String, dynamic>{
        'userId': uid,
        'type': widget.type,
        'title': _titleController.text.trim(),
        'coverColor': _coverColor,
        if (coverPhotoUrl != null) 'coverPhotoUrl': coverPhotoUrl,
        'memoriesCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (_notebookType.hasCompanion) {
        data['companion'] = _selectedAnimalId;
        data['companionName'] = _companionNameController.text.trim();
      }
      if (_notebookType.hasBirthdate && _birthdate != null) {
        data['birthdate'] = Timestamp.fromDate(_birthdate!);
      }
      if (_notebookType.hasGender) {
        data['gender'] = _gender;
      }
      if (_notebookType.hasDestination &&
          _destinationController.text.isNotEmpty) {
        data['destination'] = _destinationController.text.trim();
        if (_tripStart != null) {
          data['tripStart'] = Timestamp.fromDate(_tripStart!);
        }
        if (_tripEnd != null) {
          data['tripEnd'] = Timestamp.fromDate(_tripEnd!);
        }
      }
      if (_notebookType.hasRecipient && _recipientController.text.isNotEmpty) {
        data['recipient'] = _recipientController.text.trim();
        data['bookFrequency'] = _bookFrequency;
      }
      if (_notebookType.hasExpectedDate && _expectedDate != null) {
        data['expectedDate'] = Timestamp.fromDate(_expectedDate!);
      }

      final ref =
          await FirebaseFirestore.instance.collection('notebooks').add(data);
      if (mounted) context.go('/notebook/${ref.id}/dashboard');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          _notebookType.label,
          style: const TextStyle(
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
              Row(
                children: [
                  Text(_notebookType.emoji,
                      style: const TextStyle(fontSize: 36)),
                  const SizedBox(width: 12),
                  const Text(
                    'Paramètre ton carnet',
                    style: TextStyle(
                      fontFamily: 'PlayfairDisplay',
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ── Common: title ──
              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: widget.type == 'enfant'
                      ? 'Prénom de l\'enfant'
                      : 'Titre du carnet',
                ),
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    v == null || v.isEmpty ? 'Champs requis' : null,
              ),
              const SizedBox(height: 20),

              // ── Common: cover photo ──
              _buildCoverPhotoPicker(),
              const SizedBox(height: 20),

              // ── Enfant: gender ──
              if (_notebookType.hasGender && !_notebookType.hasExpectedDate)
                _buildGenderSelector(),

              // ── Enfant: birthdate ──
              if (_notebookType.hasBirthdate && !_notebookType.hasExpectedDate) ...[
                DateMaskField(
                  label: 'Date de naissance',
                  initialDate: _birthdate,
                  lastDate: _now,
                  firstDate: DateTime(2000),
                  onChanged: (d) => setState(() => _birthdate = d),
                ),
                const SizedBox(height: 12),
              ],

              // ── Enfant: companion ──
              if (_notebookType.hasCompanion) ...[
                const SizedBox(height: 16),
                const Text(
                  'Compagnon animal',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: AppColors.textDark),
                ),
                const SizedBox(height: 10),
                _buildAnimalChips(),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _companionNameController,
                  decoration: const InputDecoration(
                      labelText: 'Nom du compagnon'),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Champs requis' : null,
                ),
              ],

              // ── Voyage: destination + dates ──
              if (_notebookType.hasDestination) ...[
                TextFormField(
                  controller: _destinationController,
                  decoration:
                      const InputDecoration(labelText: 'Destination'),
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
              ],

              // ── Famille: recipient + frequency ──
              if (_notebookType.hasRecipient) ...[
                TextFormField(
                  controller: _recipientController,
                  decoration: const InputDecoration(
                      labelText: 'Nom du destinataire (ex : Famille Martin)'),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Fréquence du livre',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: AppColors.textDark),
                ),
                const SizedBox(height: 10),
                _buildFrequencyChips(),
              ],

              // ── Grossesse: expected date + gender ──
              if (_notebookType.hasExpectedDate) ...[
                DateMaskField(
                  label: 'Date d\'accouchement prévue',
                  initialDate: _expectedDate,
                  firstDate: DateTime.now().subtract(const Duration(days: 30)),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                  onChanged: (d) => setState(() => _expectedDate = d),
                ),
                const SizedBox(height: 16),
                _buildGenderSelector(optional: true),
              ],

              const SizedBox(height: 20),

              // ── Common: cover color ──
              const Text(
                'Couleur de couverture',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: AppColors.textDark),
              ),
              const SizedBox(height: 12),
              _buildColorPicker(),

              const SizedBox(height: 32),
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      onPressed: _save,
                      child: const Text('Créer le carnet'),
                    ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverPhotoPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Photo de couverture',
          style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textDark),
        ),
        const SizedBox(height: 10),
        if (_coverPhoto != null) ...[
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.file(
                  _coverPhoto!,
                  width: double.infinity,
                  height: 160,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: () => setState(() => _coverPhoto = null),
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
                    width: 44,
                    height: 44,
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
          style: const TextStyle(
              fontWeight: FontWeight.w600, color: AppColors.textDark),
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
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.sage.withOpacity(0.15)
                  : AppColors.white,
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
              margin: EdgeInsets.only(
                  right: opt.$1 != 'annual' ? 8 : 0),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.sage.withOpacity(0.12)
                    : AppColors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color:
                      selected ? AppColors.sage : AppColors.border,
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
        final color =
            Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
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
                color: selected
                    ? AppColors.textDark
                    : Colors.transparent,
                width: 2.5,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                          color: color.withOpacity(0.4),
                          blurRadius: 8,
                          spreadRadius: 1)
                    ]
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
          color: selected
              ? AppColors.sage.withOpacity(0.12)
              : AppColors.white,
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
