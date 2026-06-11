import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../../core/models/child_model.dart';
import '../../core/models/draft_milestone.dart';
import '../../core/services/deepseek_service.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/utils/date_precision.dart';
import '../../core/theme/app_theme.dart';
import 'widgets/flexible_date_sheet.dart';

class ScanMilestoneScreen extends StatefulWidget {
  final String childId;
  final List<DraftMilestone>? initialDrafts;

  const ScanMilestoneScreen({
    super.key,
    required this.childId,
    this.initialDrafts,
  });

  @override
  State<ScanMilestoneScreen> createState() => _ScanMilestoneScreenState();
}

class _ScanMilestoneScreenState extends State<ScanMilestoneScreen> {
  final _noteController = TextEditingController();
  bool _analyzing = false;
  bool _extractingOcr = false;
  bool _saving = false;

  int _step = 0;
  ChildModel? _child;
  List<DraftMilestone> _drafts = [];

  final _deepseek = DeepSeekService();
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadChild();
    if (widget.initialDrafts != null && widget.initialDrafts!.isNotEmpty) {
      _drafts = List.from(widget.initialDrafts!);
      _step = 1;
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadChild() async {
    final doc = await FirebaseFirestore.instance
        .collection('children')
        .doc(widget.childId)
        .get();
    if (mounted) setState(() => _child = ChildModel.fromFirestore(doc));
  }

  // ── OCR ────────────────────────────────────────────────────────────────────

  Future<void> _pickAndOcr(ImageSource source) async {
    final picked = await _picker.pickImage(source: source, imageQuality: 90);
    if (picked == null || !mounted) return;
    setState(() => _extractingOcr = true);
    try {
      final inputImage = InputImage.fromFilePath(picked.path);
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final result = await recognizer.processImage(inputImage);
      await recognizer.close();
      final text = result.text.trim();
      if (text.isNotEmpty && mounted) {
        setState(() => _noteController.text = text);
      } else if (mounted) {
        _showSnack('Aucun texte détecté sur la photo');
      }
    } catch (_) {
      if (mounted) _showSnack('Impossible de lire la photo');
    } finally {
      if (mounted) setState(() => _extractingOcr = false);
    }
  }

  // ── Analyse ────────────────────────────────────────────────────────────────

  Future<void> _analyze() async {
    final text = _noteController.text.trim();
    if (text.isEmpty) return;
    setState(() => _analyzing = true);
    try {
      final results =
          await _deepseek.extractAllMilestonesFromText(text: text);
      if (!mounted) return;
      if (results == null) {
        _showSnack('Erreur API — vérifie les logs (flutter run)');
        return;
      }
      if (results.isEmpty) {
        _showSnack('Aucun souvenir détecté — réessaie');
        return;
      }
      setState(() {
        _drafts = results;
        _step = 1;
      });
    } catch (e) {
      if (mounted) _showSnack('Erreur: $e');
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  // ── Sauvegarde ─────────────────────────────────────────────────────────────

  List<DraftMilestone> get _readyDrafts =>
      _drafts.where((d) => d.included && d.isValid).toList();

  Future<void> _saveAll() async {
    final toSave = _readyDrafts;
    if (toSave.isEmpty) return;
    setState(() => _saving = true);
    try {
      final col = FirebaseFirestore.instance.collection('milestones');
      await Future.wait(
        toSave.map((d) => col.add(d.toFirestore(widget.childId))),
      );
      if (mounted) context.go('/child/${widget.childId}');
    } catch (_) {
      _showSnack('Erreur lors de la sauvegarde');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSnack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_step == 0 ? 'Importer des notes' : 'Souvenirs détectés'),
        leading: IconButton(
          icon: Icon(_step == 0 ? Icons.close : Icons.arrow_back),
          onPressed: () {
            if (_step == 0) {
              context.go('/child/${widget.childId}');
            } else {
              setState(() {
                _step = 0;
                _drafts = [];
              });
            }
          },
        ),
      ),
      body: _step == 0 ? _buildInputStep() : _buildListStep(),
    );
  }

  // ── Étape 0 : saisie ───────────────────────────────────────────────────────

  Widget _buildInputStep() {
    final hasText = _noteController.text.trim().isNotEmpty;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Importe tes notes',
            style: TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Colle tout ton texte — même 15 événements. L\'IA les extrait tous.',
            style: TextStyle(color: AppColors.textMedium, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: _PhotoButton(
                  icon: Icons.camera_alt_outlined,
                  label: _extractingOcr ? 'Lecture...' : 'Appareil photo',
                  onTap: _extractingOcr
                      ? null
                      : () => _pickAndOcr(ImageSource.camera),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PhotoButton(
                  icon: Icons.photo_library_outlined,
                  label: _extractingOcr ? 'Lecture...' : 'Galerie',
                  onTap: _extractingOcr
                      ? null
                      : () => _pickAndOcr(ImageSource.gallery),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: Divider(color: AppColors.beige)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('ou',
                    style: const TextStyle(
                        color: AppColors.softGray, fontSize: 13)),
              ),
              const Expanded(child: Divider(color: AppColors.beige)),
            ],
          ),
          const SizedBox(height: 16),
          if (_extractingOcr)
            Container(
              height: 160,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.beige, width: 1.5),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Lecture de la photo...',
                      style: TextStyle(color: AppColors.textMedium)),
                ],
              ),
            )
          else
            TextField(
              controller: _noteController,
              maxLines: 12,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText:
                    'Colle ici toutes tes notes — dates, premiers mots, mesures, anecdotes...',
                alignLabelWithHint: true,
              ),
            ),
          const SizedBox(height: 28),
          if (_analyzing)
            const Center(child: CircularProgressIndicator())
          else
            ElevatedButton.icon(
              onPressed: hasText ? _analyze : null,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Analyser avec l\'IA'),
              style: ElevatedButton.styleFrom(
                disabledBackgroundColor: AppColors.beige,
                disabledForegroundColor: AppColors.softGray,
              ),
            ),
        ],
      ),
    );
  }

  // ── Étape 1 : liste des souvenirs ──────────────────────────────────────────

  Widget _buildListStep() {
    final ready = _readyDrafts.length;
    final total = _drafts.length;
    final needsAttention = _drafts.where((d) => d.included && !d.isValid).length;

    return Column(
      children: [
        // Bannière résumé
        Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.sage.withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.sage.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome, color: AppColors.sage, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$total souvenirs détectés · $ready prêts à enregistrer'
                  '${needsAttention > 0 ? ' · $needsAttention à compléter' : ''}',
                  style:
                      const TextStyle(color: AppColors.sage, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Liste
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            itemCount: _drafts.length,
            itemBuilder: (ctx, i) => _DraftCard(
              draft: _drafts[i],
              onToggle: () => setState(() => _drafts[i].included = !_drafts[i].included),
              onEdit: () async {
                if (_child == null) return;
                final updated = await showModalBottomSheet<DraftMilestone>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => _MilestoneEditSheet(
                    draft: _drafts[i],
                    child: _child!,
                  ),
                );
                if (updated != null && mounted) {
                  setState(() => _drafts[i] = updated);
                }
              },
            ),
          ),
        ),

        // Bouton enregistrer
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: BoxDecoration(
            color: AppColors.cream,
            border: Border(top: BorderSide(color: AppColors.beige)),
          ),
          child: _saving
              ? const Center(child: CircularProgressIndicator())
              : ElevatedButton(
                  onPressed: ready > 0 ? _saveAll : null,
                  style: ElevatedButton.styleFrom(
                    disabledBackgroundColor: AppColors.beige,
                    disabledForegroundColor: AppColors.softGray,
                  ),
                  child: Text(ready > 0
                      ? 'Enregistrer $ready souvenir${ready > 1 ? 's' : ''}'
                      : 'Complète les souvenirs d\'abord'),
                ),
        ),
      ],
    );
  }
}

// ── Carte d'un souvenir ────────────────────────────────────────────────────

class _DraftCard extends StatelessWidget {
  final DraftMilestone draft;
  final VoidCallback onToggle;
  final VoidCallback onEdit;

  const _DraftCard({
    required this.draft,
    required this.onToggle,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final cat = getMilestoneCategoryById(draft.type);
    final sub = draft.subType != null
        ? getMilestoneSubTypeById(draft.type, draft.subType!)
        : null;

    final isValid = draft.isValid;
    final isIncluded = draft.included;

    return GestureDetector(
      onTap: onEdit,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: isIncluded ? 1.0 : 0.45,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: !isIncluded
                  ? AppColors.beige
                  : isValid
                      ? AppColors.sage.withOpacity(0.4)
                      : const Color(0xFFE6A817),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              // Checkbox d'inclusion
              GestureDetector(
                onTap: onToggle,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(
                    isIncluded
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: isIncluded ? AppColors.sage : AppColors.softGray,
                    size: 22,
                  ),
                ),
              ),

              // Emoji catégorie
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.beige,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(cat.emoji, style: const TextStyle(fontSize: 20)),
              ),
              const SizedBox(width: 12),

              // Contenu
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sub?.label ?? cat.label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (draft.needsDate)
                      _StatusTag(
                        label: 'Date à confirmer',
                        color: const Color(0xFFE6A817),
                      )
                    else
                      Text(
                        formatDateWithPrecision(draft.date!, draft.datePrecision),
                        style: const TextStyle(
                          color: AppColors.textMedium,
                          fontSize: 12,
                        ),
                      ),
                    if (draft.rawContent.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        draft.rawContent,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.softGray,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (draft.needsSubType)
                      _StatusTag(
                        label: 'Sous-type à choisir',
                        color: const Color(0xFFE6A817),
                      ),
                  ],
                ),
              ),

              // Icône statut + éditer
              const SizedBox(width: 8),
              Column(
                children: [
                  Icon(
                    isValid ? Icons.check_circle : Icons.warning_amber_rounded,
                    color: isValid ? AppColors.sage : const Color(0xFFE6A817),
                    size: 18,
                  ),
                  const SizedBox(height: 4),
                  const Icon(Icons.edit_outlined,
                      color: AppColors.softGray, size: 16),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 3),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      );
}

// ── Feuille d'édition d'un souvenir ───────────────────────────────────────

class _MilestoneEditSheet extends StatefulWidget {
  final DraftMilestone draft;
  final ChildModel child;

  const _MilestoneEditSheet({required this.draft, required this.child});

  @override
  State<_MilestoneEditSheet> createState() => _MilestoneEditSheetState();
}

class _MilestoneEditSheetState extends State<_MilestoneEditSheet> {
  late String _type;
  late String? _subType;
  late DateTime? _date;
  late DatePrecision _datePrecision;
  late TextEditingController _textCtrl;
  late TextEditingController _weightCtrl;
  late TextEditingController _heightCtrl;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    _type = d.type;
    _subType = d.subType;
    _date = d.date;
    _datePrecision = d.datePrecision;
    _textCtrl = TextEditingController(text: d.rawContent);
    _weightCtrl = TextEditingController(
        text: d.weightKg != null ? d.weightKg!.toStringAsFixed(1) : '');
    _heightCtrl = TextEditingController(
        text: d.heightCm != null ? d.heightCm!.toStringAsFixed(1) : '');
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _weightCtrl.dispose();
    _heightCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final updated = DraftMilestone(
      type: _type,
      subType: _subType,
      date: _date,
      datePrecision: _datePrecision,
      rawContent: _type == 'taille_poids' ? '' : _textCtrl.text.trim(),
      weightKg: _type == 'taille_poids'
          ? double.tryParse(_weightCtrl.text.replaceAll(',', '.'))
          : null,
      heightCm: _type == 'taille_poids'
          ? double.tryParse(_heightCtrl.text.replaceAll(',', '.'))
          : null,
      included: widget.draft.included,
    );
    Navigator.pop(context, updated);
  }

  Future<void> _openDatePicker() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FlexibleDateSheet(
        currentDate: _date ?? DateTime.now(),
        currentPrecision: _datePrecision,
        minDate: widget.child.birthDate,
      ),
    );
    if (result == null || !mounted) return;
    final precision = result['precision'] as DatePrecision;
    if (precision == DatePrecision.exact) {
      final ref = _date ?? DateTime.now();
      final picked = await showDatePicker(
        context: context,
        initialDate: ref.isBefore(widget.child.birthDate)
            ? widget.child.birthDate
            : ref,
        firstDate: widget.child.birthDate,
        lastDate: DateTime.now(),
        helpText: 'Date exacte',
      );
      if (picked != null && mounted) {
        setState(() {
          _date = picked;
          _datePrecision = DatePrecision.exact;
        });
      }
    } else {
      setState(() {
        _date = result['date'] as DateTime;
        _datePrecision = precision;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(24, 20, 24, 24 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.beige,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Modifier ce souvenir',
              style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark,
              ),
            ),
            const SizedBox(height: 20),

            // Type
            const _Label('Type'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: kMilestoneCategories.map((cat) {
                final sel = _type == cat.id;
                return GestureDetector(
                  onTap: () => setState(() {
                    _type = cat.id;
                    _subType = null;
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: sel ? AppColors.sage : AppColors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: sel ? AppColors.sage : AppColors.beige),
                    ),
                    child: Text(
                      '${cat.emoji} ${cat.label}',
                      style: TextStyle(
                        color: sel ? AppColors.white : AppColors.textMedium,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),

            // Sous-type
            if (_type == 'parole' || _type == 'mouvement') ...[
              const SizedBox(height: 16),
              const _Label('Sous-type'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: getMilestoneCategoryById(_type).subTypes.map((sub) {
                  final sel = _subType == sub.id;
                  return GestureDetector(
                    onTap: () => setState(() => _subType = sub.id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: sel ? AppColors.earth : AppColors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: sel ? AppColors.earth : AppColors.beige),
                      ),
                      child: Text(
                        sub.label,
                        style: TextStyle(
                          color:
                              sel ? AppColors.white : AppColors.textMedium,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],

            // Contenu
            if (_type != 'taille_poids') ...[
              const SizedBox(height: 16),
              const _Label('Contenu'),
              const SizedBox(height: 8),
              TextField(
                controller: _textCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'Décris ce souvenir...',
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ] else ...[
              const SizedBox(height: 16),
              const _Label('Mesures'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _weightCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Poids (kg)',
                        suffixText: 'kg',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _heightCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Taille (cm)',
                        suffixText: 'cm',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ],

            // Date
            const SizedBox(height: 16),
            const _Label('Date'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _openDatePicker,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: _date == null
                      ? const Color(0xFFFFF3CD)
                      : AppColors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _date == null
                        ? const Color(0xFFE6A817)
                        : AppColors.beige,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      color: _date == null
                          ? const Color(0xFFE6A817)
                          : AppColors.textMedium,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _date == null
                            ? 'Appuie pour choisir la date'
                            : formatDateWithPrecision(_date!, _datePrecision),
                        style: TextStyle(
                          color: _date == null
                              ? const Color(0xFFB07800)
                              : AppColors.textDark,
                          fontWeight: _date == null
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
            ),

            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _confirm,
              child: const Text('Confirmer'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Widgets locaux ─────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          color: AppColors.textDark,
          fontSize: 14,
        ),
      );
}

class _PhotoButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _PhotoButton(
      {required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.beige, width: 1.5),
        ),
        child: Column(
          children: [
            Icon(icon,
                color:
                    onTap == null ? AppColors.softGray : AppColors.earth,
                size: 26),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: onTap == null
                    ? AppColors.softGray
                    : AppColors.textMedium,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
