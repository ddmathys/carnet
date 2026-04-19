import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/animals.dart';

class AddChildScreen extends StatefulWidget {
  const AddChildScreen({super.key});

  @override
  State<AddChildScreen> createState() => _AddChildScreenState();
}

class _AddChildScreenState extends State<AddChildScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _animalNameController = TextEditingController();
  DateTime? _birthDate;
  String _selectedAnimalId = 'fox';
  String _selectedColor = '#7A9E7E';
  bool _loading = false;
  int _step = 0; // 0=animal, 1=infos

  final List<String> _coverColors = [
    '#7A9E7E', '#C4956A', '#F5ECD7', '#B5C4D0', '#D4A5A5', '#A8B8A8',
  ];

  @override
  void initState() {
    super.initState();
    _animalNameController.text = kAnimals.first.defaultCompanionName;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _animalNameController.dispose();
    super.dispose();
  }

  void _selectAnimal(Animal animal) {
    setState(() {
      _selectedAnimalId = animal.id;
      _animalNameController.text = animal.defaultCompanionName;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().subtract(const Duration(days: 365)),
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
      helpText: 'Date de naissance',
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_birthDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisis une date de naissance')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await FirebaseFirestore.instance.collection('children').add({
        'parentId': uid,
        'firstName': _nameController.text.trim(),
        'birthDate': Timestamp.fromDate(_birthDate!),
        'animalId': _selectedAnimalId,
        'animalName': _animalNameController.text.trim(),
        'coverColor': _selectedColor,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) context.go('/home');
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
        title: Text(_step == 0 ? 'Choisis un compagnon' : 'Ton enfant'),
        leading: _step == 1
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _step = 0),
              )
            : null,
      ),
      body: _step == 0 ? _buildAnimalStep() : _buildInfoStep(),
    );
  }

  Widget _buildAnimalStep() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quel animal accompagnera\nvotre enfant ?',
            style: TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Il sera présent dans tous les récits du livre.',
            style: TextStyle(color: AppColors.textMedium),
          ),
          const SizedBox(height: 32),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 1.1,
              ),
              itemCount: kAnimals.length,
              itemBuilder: (_, i) {
                final animal = kAnimals[i];
                final selected = _selectedAnimalId == animal.id;
                return GestureDetector(
                  onTap: () => _selectAnimal(animal),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.sage : AppColors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected ? AppColors.sage : AppColors.beige,
                        width: 2,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(animal.emoji, style: const TextStyle(fontSize: 48)),
                        const SizedBox(height: 8),
                        Text(
                          animal.name,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: selected ? AppColors.white : AppColors.textDark,
                          ),
                        ),
                        Text(
                          '"${animal.defaultCompanionName}"',
                          style: TextStyle(
                            fontSize: 12,
                            color: selected
                                ? AppColors.cream
                                : AppColors.textMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => setState(() => _step = 1),
            child: const Text('Continuer'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoStep() {
    final animal = getAnimalById(_selectedAnimalId);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(animal.emoji, style: const TextStyle(fontSize: 40)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Super choix !',
                    style: const TextStyle(
                      fontFamily: 'PlayfairDisplay',
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Prénom de l\'enfant'),
              textCapitalization: TextCapitalization.words,
              validator: (v) => v == null || v.isEmpty ? 'Champs requis' : null,
            ),
            const SizedBox(height: 12),
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
                    const Icon(Icons.cake_outlined, color: AppColors.textMedium),
                    const SizedBox(width: 12),
                    Text(
                      _birthDate == null
                          ? 'Date de naissance'
                          : DateFormat('d MMMM yyyy', 'fr').format(_birthDate!),
                      style: TextStyle(
                        color: _birthDate == null
                            ? AppColors.softGray
                            : AppColors.textDark,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _animalNameController,
              decoration: InputDecoration(
                labelText: 'Nom du compagnon ${animal.emoji}',
                hintText: animal.defaultCompanionName,
              ),
              validator: (v) => v == null || v.isEmpty ? 'Champs requis' : null,
            ),
            const SizedBox(height: 20),
            const Text(
              'Couleur du livre',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textDark,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: _coverColors.map((hex) {
                final color = Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
                final selected = _selectedColor == hex;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = hex),
                  child: Container(
                    margin: const EdgeInsets.only(right: 10),
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? AppColors.textDark : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 32),
            _loading
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton(
                    onPressed: _save,
                    child: const Text('Créer le profil'),
                  ),
          ],
        ),
      ),
    );
  }
}
