import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../../core/models/child_model.dart';
import '../../core/services/deepseek_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/utils/date_precision.dart';
import '../../core/widgets/date_mask_field.dart';
import 'widgets/growth_curve_chart.dart';
import 'widgets/flexible_date_sheet.dart';
import 'scan_milestone_screen.dart';

class AddMilestoneScreen extends StatefulWidget {
  final String childId;
  final String? milestoneId;

  const AddMilestoneScreen({
    super.key,
    required this.childId,
    this.milestoneId,
  });

  @override
  State<AddMilestoneScreen> createState() => _AddMilestoneScreenState();
}

class _AddMilestoneScreenState extends State<AddMilestoneScreen> {
  // ── Navigation ─────────────────────────────────────────────────────────────
  int _step = 0;
  bool get _isEditing => widget.milestoneId != null;

  // ── Données enfant ─────────────────────────────────────────────────────────
  ChildModel? _child;

  // ── Étape 0 : saisie libre ─────────────────────────────────────────────────
  final _smartController = TextEditingController();
  bool _isAnalyzing = false;
  bool _showManualGrid = false;

  // ── Vocal ──────────────────────────────────────────────────────────────────
  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;

  // ── Étape 1 : formulaire ───────────────────────────────────────────────────
  String? _selectedCategory;
  String? _selectedSubType;
  DateTime _selectedDate = DateTime.now();
  DatePrecision _datePrecision = DatePrecision.exact;
  bool _dateNeedsConfirmation = false;
  final _textController = TextEditingController();
  final _weightController = TextEditingController();
  final _heightController = TextEditingController();
  bool _loading = false;

  final _deepseek = DeepSeekService();

  // ── Init / dispose ─────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _isEditing ? _loadForEdit() : _loadChild();
  }

  @override
  void dispose() {
    _smartController.dispose();
    _textController.dispose();
    _weightController.dispose();
    _heightController.dispose();
    _speech.stop();
    super.dispose();
  }

  // ── Chargement ─────────────────────────────────────────────────────────────

  Future<void> _loadChild() async {
    final doc = await FirebaseFirestore.instance
        .collection('children')
        .doc(widget.childId)
        .get();
    if (mounted) {
      setState(() {
        _child = ChildModel.fromFirestore(doc);
        _selectedDate = _child!.birthDate;
      });
    }
  }

  Future<void> _loadForEdit() async {
    final results = await Future.wait([
      FirebaseFirestore.instance.collection('children').doc(widget.childId).get(),
      FirebaseFirestore.instance.collection('milestones').doc(widget.milestoneId).get(),
    ]);
    if (!mounted) return;

    final child = ChildModel.fromFirestore(results[0]);
    final data = results[1].data() as Map<String, dynamic>;
    final precision = datePrecisionFromString(data['datePrecision']);
    final date = (data['date'] as Timestamp).toDate();
    final rawContent = data['rawContent'] as String? ?? '';
    final weightKg = (data['weightKg'] as num?)?.toDouble();
    final heightCm = (data['heightCm'] as num?)?.toDouble();

    String textValue = rawContent;
    if (data['type'] == 'parole' && rawContent.contains('" : "')) {
      final parts = rawContent.split('" : "');
      if (parts.length > 1) textValue = parts.last.replaceAll('"', '');
    } else if (data['type'] == 'mouvement' && rawContent.contains(' — ')) {
      textValue = rawContent.split(' — ').last;
    }

    setState(() {
      _child = child;
      _selectedCategory = data['type'];
      _selectedSubType = data['subType'];
      _selectedDate = date;
      _datePrecision = precision;
      _step = 1;
      if (data['type'] == 'taille_poids') {
        if (weightKg != null) _weightController.text = weightKg.toStringAsFixed(1);
        if (heightCm != null) _heightController.text = heightCm.toStringAsFixed(1);
      } else if (data['type'] != 'mouvement' || rawContent.contains(' — ')) {
        _textController.text = textValue;
      }
    });
  }

  // ── Vocal ──────────────────────────────────────────────────────────────────

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
      return;
    }

    bool available = false;
    try {
      available = await _speech.initialize(
        onError: (e) {
          if (mounted) {
            setState(() => _isListening = false);
            _showSnack('Erreur vocale: ${e.errorMsg}');
          }
        },
      );
    } catch (_) {
      if (mounted) _showSnack('Vocal non disponible — redémarre l\'app');
      return;
    }

    if (!available) {
      _showSnack('Reconnaissance vocale non disponible sur cet appareil');
      return;
    }

    setState(() => _isListening = true);
    await _speech.listen(
      onResult: (result) {
        if (mounted) {
          setState(() => _smartController.text = result.recognizedWords);
          if (result.finalResult) setState(() => _isListening = false);
        }
      },
      localeId: 'fr_FR',
      cancelOnError: true,
      partialResults: true,
    );
  }

  // ── Analyse IA ─────────────────────────────────────────────────────────────

  Future<void> _analyzeAndFill() async {
    final text = _smartController.text.trim();
    if (text.isEmpty) return;

    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    }

    setState(() => _isAnalyzing = true);
    try {
      final results = await _deepseek.extractAllMilestonesFromText(text: text);
      if (!mounted) return;
      if (results == null || results.isEmpty) {
        _showSnack('Impossible d\'analyser — réessaie');
        return;
      }

      // Plusieurs souvenirs → page de liste (ScanMilestoneScreen)
      if (results.length > 1) {
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ScanMilestoneScreen(
              childId: widget.childId,
              initialDrafts: results,
            ),
          ),
        );
        return;
      }

      // Un seul souvenir → formulaire pré-rempli
      final r = results.first;
      setState(() {
        _selectedCategory = r.type;
        _selectedSubType = r.subType;
        if (r.date != null) {
          _selectedDate = r.date!;
          _datePrecision = r.datePrecision;
          _dateNeedsConfirmation = false;
        } else {
          _selectedDate = DateTime.now();
          _datePrecision = DatePrecision.exact;
          _dateNeedsConfirmation = true;
        }
        _textController.text = r.type != 'taille_poids' ? r.rawContent : '';
        if (r.weightKg != null) _weightController.text = r.weightKg!.toStringAsFixed(1);
        if (r.heightCm != null) _heightController.text = r.heightCm!.toStringAsFixed(1);
        _step = 1;
      });
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  // ── Date picker ────────────────────────────────────────────────────────────

  String get _dateLabel => _dateNeedsConfirmation
      ? 'Date à confirmer'
      : formatDateWithPrecision(_selectedDate, _datePrecision);

  Future<void> _openDatePicker() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FlexibleDateSheet(
        currentDate: _selectedDate,
        currentPrecision: _datePrecision,
        minDate: _child!.birthDate,
      ),
    );
    if (result == null || !mounted) return;

    final precision = result['precision'] as DatePrecision;
    if (precision == DatePrecision.exact) {
      final picked = await showDatePicker(
        context: context,
        initialDate: _selectedDate.isBefore(_child!.birthDate)
            ? _child!.birthDate
            : _selectedDate,
        firstDate: _child!.birthDate,
        lastDate: DateTime.now(),
        helpText: 'Date exacte',
      );
      if (picked != null && mounted) {
        setState(() {
          _selectedDate = picked;
          _datePrecision = DatePrecision.exact;
          _dateNeedsConfirmation = false;
        });
      }
    } else {
      setState(() {
        _selectedDate = result['date'] as DateTime;
        _datePrecision = precision;
        _dateNeedsConfirmation = false;
      });
    }
  }

  // ── Sauvegarde ─────────────────────────────────────────────────────────────

  bool get _saveEnabled {
    switch (_selectedCategory) {
      case 'parole':
        return _selectedSubType != null;
      case 'mouvement':
        return _selectedSubType != null;
      case 'taille_poids':
        final w = double.tryParse(_weightController.text.replaceAll(',', '.'));
        final h = double.tryParse(_heightController.text.replaceAll(',', '.'));
        return (w != null && w > 0) || (h != null && h > 0);
      case 'anecdote':
        return _textController.text.trim().isNotEmpty;
      default:
        return _selectedCategory != null;
    }
  }

  Future<void> _save() async {
    if (!_saveEnabled) return;
    setState(() => _loading = true);
    try {
      final category = _selectedCategory!;
      final rawContent = _buildRawContent(category);
      final weightKg = category == 'taille_poids'
          ? double.tryParse(_weightController.text.replaceAll(',', '.'))
          : null;
      final heightCm = category == 'taille_poids'
          ? double.tryParse(_heightController.text.replaceAll(',', '.'))
          : null;

      final payload = {
        'childId': widget.childId,
        'type': category,
        'subType': _selectedSubType,
        'date': Timestamp.fromDate(_selectedDate),
        'datePrecision': datePrecisionToString(_datePrecision),
        'dateLabel': formatDateWithPrecision(_selectedDate, _datePrecision),
        'rawContent': rawContent,
        'photoUrl': null,
        'weightKg': weightKg,
        'heightCm': heightCm,
      };

      final col = FirebaseFirestore.instance.collection('milestones');
      if (_isEditing) {
        await col.doc(widget.milestoneId).update(payload);
      } else {
        await col.add({...payload, 'aiNarration': null, 'createdAt': FieldValue.serverTimestamp()});
      }

      if (mounted) context.go('/child/${widget.childId}');
    } catch (_) {
      _showSnack('Erreur lors de la sauvegarde');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _buildRawContent(String category) {
    switch (category) {
      case 'parole':
        final subLabel =
            getMilestoneSubTypeById(category, _selectedSubType!)?.label ?? '';
        final text = _textController.text.trim();
        return text.isNotEmpty ? '$subLabel : "$text"' : subLabel;
      case 'mouvement':
        final subLabel =
            getMilestoneSubTypeById(category, _selectedSubType!)?.label ?? '';
        final note = _textController.text.trim();
        return note.isNotEmpty ? '$subLabel — $note' : subLabel;
      case 'taille_poids':
        final parts = <String>[];
        final w = double.tryParse(_weightController.text.replaceAll(',', '.'));
        final h = double.tryParse(_heightController.text.replaceAll(',', '.'));
        if (w != null) parts.add('${w.toStringAsFixed(1)} kg');
        if (h != null) parts.add('${h.toStringAsFixed(1)} cm');
        return parts.join(' • ');
      default:
        return _textController.text.trim();
    }
  }

  Widget _buildDateSection() {
    final minDate = _child?.birthDate ?? DateTime(2000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_datePrecision == DatePrecision.exact)
          DateMaskField(
            label: 'Date',
            initialDate: _dateNeedsConfirmation ? null : _selectedDate,
            firstDate: minDate,
            lastDate: DateTime.now(),
            onChanged: (d) {
              if (d != null) {
                setState(() {
                  _selectedDate = d;
                  _dateNeedsConfirmation = false;
                  _datePrecision = DatePrecision.exact;
                });
              }
            },
          )
        else
          GestureDetector(
            onTap: () => setState(() {
              _datePrecision = DatePrecision.exact;
              _dateNeedsConfirmation = true;
            }),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: _dateNeedsConfirmation
                    ? const Color(0xFFFFF3CD)
                    : AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _dateNeedsConfirmation
                      ? const Color(0xFFE6A817)
                      : AppColors.beige,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_outlined,
                      size: 18,
                      color: _dateNeedsConfirmation
                          ? const Color(0xFFE6A817)
                          : AppColors.textMedium),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(_dateLabel,
                          style: const TextStyle(
                              color: AppColors.textDark))),
                  const Icon(Icons.edit_outlined,
                      size: 16, color: AppColors.softGray),
                ],
              ),
            ),
          ),
        const SizedBox(height: 6),
        TextButton(
          style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: _openDatePicker,
          child: const Text(
            'Saisir mois ou trimestre →',
            style: TextStyle(color: AppColors.textMedium, fontSize: 12),
          ),
        ),
      ],
    );
  }

  void _showSnack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _goBack() {
    if (_step == 0) {
      context.go('/child/${widget.childId}');
    } else {
      setState(() {
        _step = 0;
        _selectedCategory = null;
        _selectedSubType = null;
        _dateNeedsConfirmation = false;
        _textController.clear();
        _weightController.clear();
        _heightController.clear();
      });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_child == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing
            ? 'Modifier le souvenir'
            : _step == 0
                ? 'Nouveau souvenir'
                : 'Vérifier & confirmer'),
        leading: IconButton(
          icon: Icon(_step == 0 ? Icons.close : Icons.arrow_back),
          onPressed: _goBack,
        ),
      ),
      body: _step == 0 ? _buildSmartInputStep() : _buildDetailsStep(),
    );
  }

  // ── Étape 0 : saisie libre + vocal + import ────────────────────────────────

  Widget _buildSmartInputStep() {
    final hasText = _smartController.text.trim().isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Qu\'as-tu à noter ?',
            style: TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Écris ou dicte librement — l\'IA classe automatiquement.',
            style: TextStyle(color: AppColors.textMedium, fontSize: 14),
          ),
          const SizedBox(height: 20),

          // Zone de texte + bouton micro
          Stack(
            children: [
              TextField(
                controller: _smartController,
                maxLines: 6,
                onChanged: (_) => setState(() {}),
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText:
                      'Ex : "Léa a dit maman pour la première fois ce matin…"',
                  alignLabelWithHint: true,
                  contentPadding:
                      EdgeInsets.fromLTRB(16, 14, 52, 14),
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: GestureDetector(
                  onTap: _toggleListening,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _isListening
                          ? const Color(0xFFD64045)
                          : AppColors.sage,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isListening ? Icons.stop : Icons.mic,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
              ),
            ],
          ),

          if (_isListening) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFFD64045),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Écoute en cours… parle maintenant',
                  style: TextStyle(
                      color: Color(0xFFD64045), fontSize: 13),
                ),
              ],
            ),
          ],

          const SizedBox(height: 20),

          // Bouton analyser
          if (_isAnalyzing)
            const Center(child: CircularProgressIndicator())
          else
            ElevatedButton.icon(
              onPressed: hasText ? _analyzeAndFill : null,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Analyser avec l\'IA'),
              style: ElevatedButton.styleFrom(
                disabledBackgroundColor: AppColors.beige,
                disabledForegroundColor: AppColors.softGray,
              ),
            ),

          const SizedBox(height: 20),

          // Séparateur
          const Row(
            children: [
              Expanded(child: Divider(color: AppColors.beige)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('ou',
                    style: TextStyle(
                        color: AppColors.softGray, fontSize: 13)),
              ),
              Expanded(child: Divider(color: AppColors.beige)),
            ],
          ),

          const SizedBox(height: 16),

          // Import depuis une note
          GestureDetector(
            onTap: () => context
                .push('/child/${widget.childId}/scan-milestone'),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.beige, width: 1.5),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.document_scanner_outlined,
                      color: AppColors.earth, size: 20),
                  SizedBox(width: 10),
                  Text(
                    'Importer depuis une note',
                    style: TextStyle(
                      color: AppColors.earth,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  SizedBox(width: 6),
                  Text('· photo ou texte long',
                      style: TextStyle(
                          color: AppColors.softGray, fontSize: 12)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Choix manuel (repli)
          Center(
            child: TextButton(
              onPressed: () =>
                  setState(() => _showManualGrid = !_showManualGrid),
              child: Text(
                _showManualGrid
                    ? 'Masquer le choix manuel'
                    : 'Choisir le type manuellement',
                style: const TextStyle(
                    color: AppColors.softGray, fontSize: 13),
              ),
            ),
          ),

          if (_showManualGrid) ...[
            const SizedBox(height: 8),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
              children: kMilestoneCategories.where((c) => !c.isLegacy).map((cat) {
                return GestureDetector(
                  onTap: () => setState(() {
                    _selectedCategory = cat.id;
                    _step = 1;
                  }),
                  child: Container(
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
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(cat.emoji,
                            style: const TextStyle(fontSize: 40)),
                        const SizedBox(height: 10),
                        Text(
                          cat.label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDark,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  // ── Étape 1 : formulaire selon catégorie ──────────────────────────────────

  Widget _buildDetailsStep() {
    switch (_selectedCategory) {
      case 'parole':
        return _buildParoleForm();
      case 'mouvement':
        return _buildMouvementForm();
      case 'taille_poids':
        return _buildTaillePoidsForm();
      default:
        return _buildAnecdoteForm();
    }
  }

  Widget _buildParoleForm() {
    final cat = getMilestoneCategoryById('parole');
    final selectedSub = _selectedSubType != null
        ? getMilestoneSubTypeById('parole', _selectedSubType!)
        : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('💬 Type de parole'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: cat.subTypes.map((sub) {
              return GestureDetector(
                onTap: () => setState(() => _selectedSubType = sub.id),
                child: _Pill(
                    label: sub.label,
                    selected: _selectedSubType == sub.id),
              );
            }).toList(),
          ),
          if (selectedSub != null && selectedSub.hasFreeText) ...[
            const SizedBox(height: 20),
            const _SectionTitle('Qu\'a-t-il/elle dit ?'),
            const SizedBox(height: 8),
            TextField(
              controller: _textController,
              decoration: const InputDecoration(
                  hintText: '"maman", "au revoir", ...'),
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: 20),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
              label: _isEditing ? 'Mettre à jour' : 'Enregistrer ce souvenir',
              onPressed: _save),
        ],
      ),
    );
  }

  Widget _buildMouvementForm() {
    final cat = getMilestoneCategoryById('mouvement');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('🏃 Type de mouvement'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: cat.subTypes.map((sub) {
              return GestureDetector(
                onTap: () => setState(() => _selectedSubType = sub.id),
                child: _Pill(
                    label: sub.label,
                    selected: _selectedSubType == sub.id),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          _buildDateSection(),
          const SizedBox(height: 16),
          TextField(
            controller: _textController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Note (optionnel)',
              hintText: 'Ajoute un détail...',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
              label: _isEditing ? 'Mettre à jour' : 'Enregistrer ce souvenir',
              onPressed: _save),
        ],
      ),
    );
  }

  Widget _buildTaillePoidsForm() {
    final weightVal =
        double.tryParse(_weightController.text.replaceAll(',', '.'));
    final heightVal =
        double.tryParse(_heightController.text.replaceAll(',', '.'));

    final ageAtDate = () {
      final months =
          (_selectedDate.year - _child!.birthDate.year) * 12 +
              _selectedDate.month -
              _child!.birthDate.month;
      return months.clamp(0, 24);
    }();

    final showWeight = weightVal != null && weightVal > 0;
    final showHeight = heightVal != null && heightVal > 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('📊 Mesures'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _weightController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Poids (kg)',
                    hintText: '8.5',
                    suffixText: 'kg',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _heightController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Taille (cm)',
                    hintText: '72',
                    suffixText: 'cm',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (showWeight) ...[
            GrowthCurveChart(
              gender: _child!.gender,
              isWeight: true,
              ageMonths: ageAtDate,
              value: weightVal,
            ),
            const SizedBox(height: 20),
          ],
          if (showHeight) ...[
            GrowthCurveChart(
              gender: _child!.gender,
              isWeight: false,
              ageMonths: ageAtDate,
              value: heightVal,
            ),
            const SizedBox(height: 20),
          ],
          if (!showWeight && !showHeight) ...[
            GrowthCurveChart(
              gender: _child!.gender,
              isWeight: true,
              ageMonths: ageAtDate,
              value: null,
            ),
            const SizedBox(height: 20),
          ],
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
              label: _isEditing ? 'Mettre à jour' : 'Enregistrer ce souvenir',
              onPressed: _save),
        ],
      ),
    );
  }

  Widget _buildAnecdoteForm() {
    final cat = getMilestoneCategoryById(_selectedCategory ?? 'anecdote');
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('${cat.emoji} ${cat.label}'),
          if (cat.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              cat.description,
              style: const TextStyle(color: AppColors.textMedium, fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _textController,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Raconte ce moment... (optionnel)',
              hintText: 'Ajoute des détails, émotions, anecdotes...',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
              label: _isEditing ? 'Mettre à jour' : 'Enregistrer ce souvenir',
              onPressed: _save),
        ],
      ),
    );
  }
}

// ── Widgets réutilisables ──────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          color: AppColors.textDark,
          fontSize: 15,
        ),
      );
}

class _Pill extends StatelessWidget {
  final String label;
  final bool selected;
  const _Pill({required this.label, required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? AppColors.sage : AppColors.white,
        borderRadius: BorderRadius.circular(22),
        border:
            Border.all(color: selected ? AppColors.sage : AppColors.beige),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? AppColors.white : AppColors.textMedium,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _DatePickerButton extends StatelessWidget {
  final String label;
  final bool highlighted;
  final VoidCallback onTap;

  const _DatePickerButton({
    required this.label,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: highlighted
              ? const Color(0xFFFFF3CD)
              : AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: highlighted
                ? const Color(0xFFE6A817)
                : AppColors.beige,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.calendar_today_outlined,
              color: highlighted
                  ? const Color(0xFFE6A817)
                  : AppColors.textMedium,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: highlighted
                      ? const Color(0xFFB07800)
                      : AppColors.textDark,
                  fontWeight: highlighted
                      ? FontWeight.w500
                      : FontWeight.normal,
                ),
              ),
            ),
            const Icon(Icons.expand_more,
                color: AppColors.softGray, size: 18),
          ],
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  final bool enabled;
  final bool loading;
  final String label;
  final VoidCallback onPressed;

  const _SaveButton({
    required this.enabled,
    required this.loading,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return ElevatedButton(
      onPressed: enabled ? onPressed : null,
      style: ElevatedButton.styleFrom(
        disabledBackgroundColor: AppColors.beige,
        disabledForegroundColor: AppColors.softGray,
      ),
      child: Text(label),
    );
  }
}
