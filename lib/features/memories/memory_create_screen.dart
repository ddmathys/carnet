import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/draft_milestone.dart';
import '../../core/services/deepseek_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/audio_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/constants/notebook_types.dart';
import '../../core/utils/date_precision.dart';
import '../../core/widgets/date_mask_field.dart';
import '../milestones/widgets/growth_curve_chart.dart';
import '../milestones/widgets/flexible_date_sheet.dart';

class MemoryCreateScreen extends StatefulWidget {
  final String notebookId;
  final String? memoryId;

  const MemoryCreateScreen({
    super.key,
    required this.notebookId,
    this.memoryId,
  });

  @override
  State<MemoryCreateScreen> createState() => _MemoryCreateScreenState();
}

class _MemoryCreateScreenState extends State<MemoryCreateScreen> {
  int _step = 0;
  bool get _isEditing => widget.memoryId != null;

  NotebookModel? _notebook;

  // Step 0: smart input
  final _smartController = TextEditingController();
  bool _isAnalyzing = false;
  bool _showManualGrid = false;
  // L'analyse IA tourne encore en arrière-plan (formulaire déjà ouvert).
  bool _analysisPending = false;
  Timer? _analysisTimeoutTimer;

  // Voice (speech-to-text → remplit le texte)
  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;

  // Mémo vocal (audio attaché au souvenir)
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecording = false;
  bool _isPlayingMemo = false;
  String? _localAudioPath; // nouvel enregistrement local non encore uploadé
  String? _existingAudioUrl; // audio déjà stocké (mode édition)
  bool _audioRemoved = false; // l'utilisateur a supprimé l'audio existant
  int? _audioDurationMs;
  DateTime? _recordStartedAt;

  // Step 1: form
  String? _selectedCategory;
  String? _selectedSubType;
  DateTime _selectedDate = DateTime.now();
  DatePrecision _datePrecision = DatePrecision.exact;
  bool _dateNeedsConfirmation = true; // new memories require explicit date
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _textController = TextEditingController();
  final _weightController = TextEditingController();
  final _heightController = TextEditingController();
  bool _loading = false;
  String? _saveStatus; // libellé affiché sous le spinner pendant la sauvegarde

  // Photos (multi)
  final List<File> _localPhotos = [];
  final List<String> _existingPhotoUrls = [];
  final List<String> _removedPhotoUrls = [];
  final _picker = ImagePicker();

  final _deepseek = DeepSeekService();

  @override
  void initState() {
    super.initState();
    _isEditing ? _loadForEdit() : _loadNotebook();
  }

  @override
  void dispose() {
    _smartController.dispose();
    _titleController.dispose();
    _locationController.dispose();
    _textController.dispose();
    _weightController.dispose();
    _heightController.dispose();
    _speech.stop();
    _recorder.dispose();
    _audioPlayer.dispose();
    _analysisTimeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadNotebook() async {
    final doc = await FirebaseFirestore.instance
        .collection('notebooks')
        .doc(widget.notebookId)
        .get();
    if (mounted && doc.exists) {
      setState(() => _notebook = NotebookModel.fromFirestore(doc));
    }
  }

  Future<void> _loadForEdit() async {
    final results = await Future.wait([
      FirebaseFirestore.instance
          .collection('notebooks')
          .doc(widget.notebookId)
          .get(),
      FirebaseFirestore.instance
          .collection('memories')
          .doc(widget.memoryId)
          .get(),
    ]);
    if (!mounted) return;

    final notebook = NotebookModel.fromFirestore(results[0]);
    final data = results[1].data() as Map<String, dynamic>;
    final precision = datePrecisionFromString(data['datePrecision']);
    final date = (data['date'] as Timestamp).toDate();
    final rawContent = data['rawContent'] as String? ?? '';
    final title = data['title'] as String? ?? '';
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
      _notebook = notebook;
      _selectedCategory = data['type'];
      _selectedSubType = data['subType'];
      _titleController.text = title;
      _locationController.text = data['location'] as String? ?? '';
      _selectedDate = date;
      _datePrecision = precision;
      final photoUrl = data['photoUrl'] as String?;
      final mediaUrls =
          List<String>.from(data['mediaUrls'] as List<dynamic>? ?? []);
      // Build existing URLs list (deduplicated)
      final existing = <String>{
        if (photoUrl != null && photoUrl.isNotEmpty) photoUrl,
        ...mediaUrls,
      }.toList();
      _existingPhotoUrls.addAll(existing);
      _existingAudioUrl = data['audioUrl'] as String?;
      _audioDurationMs = (data['audioDurationMs'] as num?)?.toInt();
      _dateNeedsConfirmation = false; // editing: date already confirmed
      _step = 1;
      if (data['type'] == 'taille_poids') {
        if (weightKg != null) _weightController.text = weightKg.toStringAsFixed(1);
        if (heightCm != null) _heightController.text = heightCm.toStringAsFixed(1);
      } else if (data['type'] != 'mouvement' || rawContent.contains(' — ')) {
        _textController.text = textValue;
      }
    });
  }

  // ── EXIF helpers ────────────────────────────────────────────────────────────

  double _rationalStr(String s) {
    final p = s.trim().split('/');
    if (p.length == 2) {
      final n = double.tryParse(p[0]);
      final d = double.tryParse(p[1]);
      if (n != null && d != null && d != 0) return n / d;
    }
    return double.tryParse(s.trim()) ?? 0;
  }

  double? _parseGpsCoord(String printable, String ref) {
    final parts = printable.split(', ');
    if (parts.isEmpty) return null;
    double coord = _rationalStr(parts[0]);
    if (parts.length > 1) coord += _rationalStr(parts[1]) / 60;
    if (parts.length > 2) coord += _rationalStr(parts[2]) / 3600;
    if (coord == 0) return null;
    if (ref == 'S' || ref == 'W') coord = -coord;
    return coord;
  }

  Future<String?> _reverseGeocode(double lat, double lon) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$lat&lon=$lon&format=json&accept-language=fr',
      );
      final res = await http.get(
        uri,
        headers: {'User-Agent': 'FolioApp/1.0'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final addr = data['address'] as Map<String, dynamic>?;
      if (addr == null) return null;

      // Priority: specific venue → neighbourhood → city
      final venue = (addr['tourism'] ?? addr['amenity'] ?? addr['leisure'] ??
          addr['historic'] ?? addr['building']) as String?;
      final city = (addr['city'] ?? addr['town'] ?? addr['village'] ??
          addr['municipality']) as String?;

      if (venue != null && city != null) return '$venue, $city';
      if (venue != null) return venue;
      if (city != null) return city;

      // Fallback: first 2 parts of display_name
      final display = data['display_name'] as String?;
      if (display != null) {
        return display.split(',').take(2).map((s) => s.trim()).join(', ');
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _applyExifFromPhoto(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final tags = await readExifFromBytes(bytes);

      // ── Date ────────────────────────────────────────────────────────────────
      final raw =
          (tags['EXIF DateTimeOriginal'] ?? tags['Image DateTime'])?.toString();
      if (raw != null && raw.isNotEmpty) {
        final parts = raw.split(' ');
        if (parts.isNotEmpty) {
          final d = parts[0].split(':');
          if (d.length >= 3) {
            final year = int.tryParse(d[0]);
            final month = int.tryParse(d[1]);
            final day = int.tryParse(d[2]);
            if (year != null && month != null && day != null && mounted) {
              setState(() {
                _selectedDate = DateTime(year, month, day);
                _datePrecision = DatePrecision.exact;
                _dateNeedsConfirmation = false;
              });
            }
          }
        }
      }

      // ── GPS → lieu ──────────────────────────────────────────────────────────
      final latTag = tags['GPS GPSLatitude'];
      final latRef = tags['GPS GPSLatitudeRef']?.printable ?? 'N';
      final lonTag = tags['GPS GPSLongitude'];
      final lonRef = tags['GPS GPSLongitudeRef']?.printable ?? 'E';

      if (latTag != null && lonTag != null && _locationController.text.isEmpty) {
        final lat = _parseGpsCoord(latTag.printable, latRef);
        final lon = _parseGpsCoord(lonTag.printable, lonRef);
        if (lat != null && lon != null) {
          final place = await _reverseGeocode(lat, lon);
          if (place != null && mounted && _locationController.text.isEmpty) {
            setState(() => _locationController.text = place);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _pickPhotos(ImageSource source) async {
    try {
      if (source == ImageSource.gallery) {
        final picked = await _picker.pickMultiImage(
            imageQuality: 80, maxWidth: 1920);
        if (picked.isNotEmpty && mounted) {
          final files = picked.map((x) => File(x.path)).toList();
          setState(() => _localPhotos.addAll(files));
          // Read EXIF (date + GPS location) from the first photo only
          await _applyExifFromPhoto(files.first);
        }
      } else {
        final picked = await _picker.pickImage(
            source: source, imageQuality: 80, maxWidth: 1920);
        if (picked != null && mounted) {
          final file = File(picked.path);
          setState(() => _localPhotos.add(file));
          await _applyExifFromPhoto(file);
        }
      }
    } catch (_) {
      _showSnack('Impossible d\'accéder à la photo');
    }
  }

  void _removeExistingPhoto(String url) {
    setState(() {
      _existingPhotoUrls.remove(url);
      _removedPhotoUrls.add(url);
    });
  }

  void _removeLocalPhoto(int index) {
    setState(() => _localPhotos.removeAt(index));
  }

  Future<void> _showPhotoSourceSheet() async {
    await showModalBottomSheet<void>(
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
              onTap: () {
                Navigator.pop(context);
                _pickPhotos(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: AppColors.sage),
              title: const Text('Choisir depuis la galerie'),
              subtitle: const Text('Sélection multiple possible'),
              onTap: () {
                Navigator.pop(context);
                _pickPhotos(ImageSource.gallery);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

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
            _showSnack('Erreur vocale : ${e.errorMsg}');
          }
        },
      );
    } catch (_) {
      if (mounted) _showSnack('Vocal non disponible');
      return;
    }
    if (!available) {
      _showSnack('Reconnaissance vocale non disponible');
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

  // ── Mémo vocal ──────────────────────────────────────────────────────────────

  bool get _hasAudio =>
      _localAudioPath != null ||
      (_existingAudioUrl != null && !_audioRemoved);

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final path = await _recorder.stop();
      final ms = _recordStartedAt != null
          ? DateTime.now().difference(_recordStartedAt!).inMilliseconds
          : null;
      if (mounted) {
        setState(() {
          _isRecording = false;
          if (path != null) {
            _localAudioPath = path;
            _audioDurationMs = ms;
            // Un nouvel enregistrement remplace l'audio existant.
            if (_existingAudioUrl != null) _audioRemoved = true;
          }
        });
      }
      return;
    }

    try {
      if (!await _recorder.hasPermission()) {
        _showSnack('Micro non autorisé');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/memo_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioPlayer.stop();
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      if (mounted) {
        setState(() {
          _isRecording = true;
          _isPlayingMemo = false;
          _recordStartedAt = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) _showSnack('Enregistrement impossible : $e');
    }
  }

  Future<void> _togglePlayMemo() async {
    if (_isPlayingMemo) {
      await _audioPlayer.stop();
      if (mounted) setState(() => _isPlayingMemo = false);
      return;
    }
    try {
      _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _isPlayingMemo = false);
      });
      if (_localAudioPath != null) {
        await _audioPlayer.play(DeviceFileSource(_localAudioPath!));
      } else if (_existingAudioUrl != null) {
        await _audioPlayer.play(UrlSource(_existingAudioUrl!));
      } else {
        return;
      }
      if (mounted) setState(() => _isPlayingMemo = true);
    } catch (e) {
      if (mounted) _showSnack('Lecture impossible : $e');
    }
  }

  void _removeAudio() {
    setState(() {
      _audioPlayer.stop();
      _isPlayingMemo = false;
      _localAudioPath = null;
      _audioDurationMs = null;
      if (_existingAudioUrl != null) _audioRemoved = true;
    });
  }

  String _formatAudioDuration(int? ms) {
    if (ms == null || ms <= 0) return '';
    final totalSec = (ms / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '${m.toString().padLeft(1, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _analyzeAndFill() async {
    final text = _smartController.text.trim();
    if (text.isEmpty) return;
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    }
    setState(() {
      _isAnalyzing = true;
      _analysisPending = true;
    });

    // Si l'IA dépasse 5 s, on ouvre quand même le formulaire pour que
    // l'utilisateur puisse enregistrer un mémo vocal / remplir sans attendre.
    // L'analyse continue en arrière-plan et complète les champs vides à son
    // retour (sans écraser ce que l'utilisateur a déjà saisi).
    _analysisTimeoutTimer?.cancel();
    _analysisTimeoutTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || !_analysisPending) return;
      setState(() {
        _isAnalyzing = false; // libère le spinner bloquant de l'étape 0
        if (_step == 0) _step = 1; // ouvre le formulaire (catégorie par défaut)
      });
    });

    try {
      final results = await _deepseek.extractAllMilestonesFromText(text: text);
      _analysisTimeoutTimer?.cancel();
      if (!mounted) return;
      if (results == null || results.isEmpty) {
        setState(() {
          _isAnalyzing = false;
          _analysisPending = false;
        });
        _showSnack('Impossible d\'analyser — réessaie');
        return;
      }
      _applyAnalysis(results.first);
    } catch (_) {
      _analysisTimeoutTimer?.cancel();
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _analysisPending = false;
        });
        _showSnack('Impossible d\'analyser — réessaie');
      }
    }
  }

  /// Applique le résultat de l'IA. Si le formulaire a déjà été ouvert via le
  /// délai de 5 s et que l'utilisateur a commencé à le remplir, on préserve
  /// ses saisies et on ne complète que les champs encore vides.
  void _applyAnalysis(DraftMilestone r) {
    // Le formulaire est déjà ouvert si l'analyse est revenue après le timeout.
    final advancedEarly = _step == 1;
    final userTouchedForm = advancedEarly &&
        (_selectedSubType != null ||
            _textController.text.trim().isNotEmpty ||
            _weightController.text.trim().isNotEmpty ||
            _heightController.text.trim().isNotEmpty);

    setState(() {
      if (!userTouchedForm) {
        // Cas normal : on applique entièrement la classification de l'IA.
        _selectedCategory = r.type;
        _selectedSubType = r.subType;
        _textController.text = r.type != 'taille_poids' ? r.rawContent : '';
        if (r.weightKg != null) {
          _weightController.text = r.weightKg!.toStringAsFixed(1);
        }
        if (r.heightCm != null) {
          _heightController.text = r.heightCm!.toStringAsFixed(1);
        }
      } else {
        // L'utilisateur a déjà saisi quelque chose → on garde sa catégorie.
        _selectedCategory ??= r.type;
        _selectedSubType ??= r.subType;
      }

      // ── Date ──────────────────────────────────────────────────────────────
      // On applique la date de l'IA seulement si elle n'a pas déjà été fixée
      // (ni par EXIF, ni manuellement) — _dateNeedsConfirmation le garantit.
      final exifAlreadySetDate = !_dateNeedsConfirmation && _hasPhotos;
      if (r.date != null && _dateNeedsConfirmation && !exifAlreadySetDate) {
        _selectedDate = r.date!;
        _datePrecision = r.datePrecision;
        _dateNeedsConfirmation = false;
      }

      // ── Titre & lieu (remplis seulement si vides) ─────────────────────────
      if (_titleController.text.isEmpty &&
          r.title != null &&
          r.title!.isNotEmpty) {
        _titleController.text = r.title!;
      }
      if (_locationController.text.isEmpty &&
          r.location != null &&
          r.location!.isNotEmpty) {
        _locationController.text = r.location!;
      }

      _analysisPending = false;
      _isAnalyzing = false;
      _step = 1;
    });
  }

  String get _dateLabel => _dateNeedsConfirmation
      ? 'Date à confirmer'
      : formatDateWithPrecision(_selectedDate, _datePrecision);

  Future<void> _openDatePicker() async {
    final minDate = _notebook?.birthdate ?? DateTime(2000);
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FlexibleDateSheet(
        currentDate: _selectedDate,
        currentPrecision: _datePrecision,
        minDate: minDate,
      ),
    );
    if (result == null || !mounted) return;
    final precision = result['precision'] as DatePrecision;
    if (precision == DatePrecision.exact) {
      final picked = await showDatePicker(
        context: context,
        initialDate:
            _selectedDate.isBefore(minDate) ? minDate : _selectedDate,
        firstDate: minDate,
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

  bool get _hasPhotos =>
      _existingPhotoUrls.isNotEmpty || _localPhotos.isNotEmpty;

  String? get _missingFieldsHint {
    final missing = <String>[];
    if (_titleController.text.trim().isEmpty) missing.add('titre');
    if (_locationController.text.trim().isEmpty) missing.add('lieu');
    if (_dateNeedsConfirmation) missing.add('date');
    if ((_selectedCategory == 'anecdote' || (_selectedCategory != 'taille_poids' && _selectedCategory != 'parole' && _selectedCategory != 'mouvement')) &&
        _textController.text.trim().isEmpty) missing.add('description');
    if (missing.isEmpty) return null;
    return 'Manque : ${missing.join(', ')}';
  }

  bool get _saveEnabled {
    // All memories require title, location, and a confirmed date
    if (_titleController.text.trim().isEmpty) return false;
    if (_locationController.text.trim().isEmpty) return false;
    if (_dateNeedsConfirmation) return false;
    switch (_selectedCategory) {
      case 'parole':
        return _selectedSubType != null;
      case 'mouvement':
        return _selectedSubType != null;
      case 'taille_poids':
        final w =
            double.tryParse(_weightController.text.replaceAll(',', '.'));
        final h =
            double.tryParse(_heightController.text.replaceAll(',', '.'));
        return (w != null && w > 0) || (h != null && h > 0);
      case 'anecdote':
        return _textController.text.trim().isNotEmpty;
      default:
        return _selectedCategory != null;
    }
  }

  Future<void> _save() async {
    if (!_saveEnabled) return;
    final hasMedia = _localPhotos.isNotEmpty || _localAudioPath != null;
    setState(() {
      _loading = true;
      _saveStatus = hasMedia ? 'Envoi des photos et du son…' : null;
    });
    try {
      final category = _selectedCategory!;
      final rawContent = _buildRawContent(category);
      final weightKg = category == 'taille_poids'
          ? double.tryParse(_weightController.text.replaceAll(',', '.'))
          : null;
      final heightCm = category == 'taille_poids'
          ? double.tryParse(_heightController.text.replaceAll(',', '.'))
          : null;

      // ── Media handling ───────────────────────────────────────────────────
      // On lance compression+upload des photos ET du nouvel audio EN PARALLÈLE
      // (avant c'était séquentiel : photos puis audio), et on supprime en même
      // temps les médias retirés. Tout démarre ici, on n'attend qu'ensuite.
      final photoUploadFuture = PhotoService.uploadMultiplePhotos(
        photos: _localPhotos,
        notebookId: widget.notebookId,
      );

      final Future<String?> audioUploadFuture = _localAudioPath != null
          ? AudioService.uploadMemoryAudio(
              audio: File(_localAudioPath!),
              notebookId: widget.notebookId,
            )
          : Future<String?>.value(_audioRemoved ? null : _existingAudioUrl);

      // Suppressions des médias retirés/remplacés (indépendantes des uploads).
      final deletions = <Future<void>>[
        ..._removedPhotoUrls.map(PhotoService.deletePhotoByUrl),
      ];
      // L'ancien audio est supprimé s'il est remplacé OU retiré sans remplacement.
      if (_existingAudioUrl != null && (_localAudioPath != null || _audioRemoved)) {
        deletions.add(AudioService.deleteAudioByUrl(_existingAudioUrl));
      }
      final deletionsFuture = Future.wait(deletions);

      final newUrls = await photoUploadFuture;
      final audioUrl = await audioUploadFuture;
      await deletionsFuture;

      final allUrls = [..._existingPhotoUrls, ...newUrls];
      final photoUrl = allUrls.isNotEmpty ? allUrls.first : null;
      final audioDurationMs = audioUrl != null ? _audioDurationMs : null;
      // ────────────────────────────────────────────────────────────────────

      if (mounted) setState(() => _saveStatus = 'Enregistrement…');

      final titleValue = _titleController.text.trim();
      final locationValue = _locationController.text.trim();
      final payload = {
        'notebookId': widget.notebookId,
        'type': category,
        'subType': _selectedSubType,
        'title': titleValue.isEmpty ? null : titleValue,
        'location': locationValue.isEmpty ? null : locationValue,
        'date': Timestamp.fromDate(_selectedDate),
        'datePrecision': datePrecisionToString(_datePrecision),
        'dateLabel': formatDateWithPrecision(_selectedDate, _datePrecision),
        'rawContent': rawContent,
        'mediaUrls': allUrls,
        'photoUrl': photoUrl,
        'audioUrl': audioUrl,
        'audioDurationMs': audioDurationMs,
        'weightKg': weightKg,
        'heightCm': heightCm,
      };

      final col = FirebaseFirestore.instance.collection('memories');
      if (_isEditing) {
        await col.doc(widget.memoryId).update(payload);
      } else {
        await col.add({
          ...payload,
          'aiNarration': null,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      await FirebaseFirestore.instance
          .collection('notebooks')
          .doc(widget.notebookId)
          .update({
        'lastMemoryAt': Timestamp.fromDate(_selectedDate),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (mounted) context.go('/notebook/${widget.notebookId}/memories');
    } catch (e) {
      if (!mounted) return;
      final msg = _friendlyError(e);
      _showSnack(msg);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _saveStatus = null;
        });
      }
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('permission-denied') || s.contains('Permission')) {
      return 'Permission refusée — vérifie les règles Firebase Storage dans la console.';
    }
    if (s.contains('storage')) return 'Erreur Storage : $s';
    if (s.contains('network') || s.contains('Network')) {
      return 'Pas de connexion internet.';
    }
    return 'Erreur : $s';
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
        final w =
            double.tryParse(_weightController.text.replaceAll(',', '.'));
        final h =
            double.tryParse(_heightController.text.replaceAll(',', '.'));
        if (w != null) parts.add('${w.toStringAsFixed(1)} kg');
        if (h != null) parts.add('${h.toStringAsFixed(1)} cm');
        return parts.join(' • ');
      default:
        return _textController.text.trim();
    }
  }

  void _showSnack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _goBack() {
    if (_step == 0) {
      context.go('/notebook/${widget.notebookId}/memories');
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

  @override
  Widget build(BuildContext context) {
    if (_notebook == null) {
      return const Scaffold(
          backgroundColor: AppColors.background,
          body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          _isEditing
              ? 'Modifier le souvenir'
              : _step == 0
                  ? 'Nouveau souvenir'
                  : 'Vérifier & confirmer',
          style: const TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontWeight: FontWeight.bold,
              color: AppColors.textDark),
        ),
        leading: IconButton(
          icon: Icon(
            _step == 0 ? Icons.close : Icons.arrow_back,
            color: AppColors.textDark,
          ),
          onPressed: _goBack,
        ),
      ),
      body: _step == 0
          ? _buildSmartInputStep()
          : Column(
              children: [
                if (_analysisPending) _buildAnalysisBanner(),
                Expanded(child: _buildDetailsStep()),
              ],
            ),
    );
  }

  Widget _buildAnalysisBanner() {
    return Container(
      width: double.infinity,
      color: AppColors.sage.withOpacity(0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.sage),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Analyse IA en cours… les champs vides se rempliront automatiquement. Tu peux déjà enregistrer un mémo vocal.',
              style: TextStyle(color: AppColors.textMedium, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmartInputStep() {
    final hasText = _smartController.text.trim().isNotEmpty;
    final notebookType = getNotebookTypeById(_notebook!.type);

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
          Stack(
            children: [
              TextField(
                controller: _smartController,
                maxLines: 6,
                onChanged: (_) => setState(() {}),
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: notebookType.memoryPlaceholder,
                  alignLabelWithHint: true,
                  contentPadding: const EdgeInsets.fromLTRB(16, 14, 52, 14),
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
                          ? AppColors.error
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
                  decoration: BoxDecoration(
                    color: AppColors.error,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Écoute en cours…',
                  style: TextStyle(color: AppColors.error, fontSize: 13),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          // ── Photos (visible dès l'étape 0)
          _buildPhotoSection(),
          const SizedBox(height: 20),

          if (_isAnalyzing)
            const Center(child: CircularProgressIndicator())
          else
            ElevatedButton.icon(
              onPressed: hasText ? _analyzeAndFill : null,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Analyser avec l\'IA'),
              style: ElevatedButton.styleFrom(
                disabledBackgroundColor: AppColors.background,
                disabledForegroundColor: AppColors.softGray,
              ),
            ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Icon(Icons.lock_outline, size: 13, color: AppColors.softGray),
              SizedBox(width: 5),
              Expanded(
                child: Text(
                  'L\'IA lit ton texte et remplit automatiquement le type, la date, le lieu et le titre. Tes photos ne sont pas envoyées.',
                  style: TextStyle(color: AppColors.softGray, fontSize: 12, height: 1.4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Row(
            children: [
              Expanded(child: Divider(color: Color(0xFFDDD8CC))),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('ou',
                    style:
                        TextStyle(color: AppColors.softGray, fontSize: 13)),
              ),
              Expanded(child: Divider(color: Color(0xFFDDD8CC))),
            ],
          ),
          const SizedBox(height: 12),
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
              children:
                  kMilestoneCategories.where((c) => !c.isLegacy).map((cat) {
                return GestureDetector(
                  onTap: () => setState(() {
                    _selectedCategory = cat.id;
                    _step = 1;
                  }),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: const Color(0xFFDDD8CC), width: 0.5),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(cat.emoji,
                            style: const TextStyle(fontSize: 36)),
                        const SizedBox(height: 8),
                        Text(
                          cat.label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDark,
                            fontSize: 12,
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
            children: cat.subTypes
                .map((sub) => GestureDetector(
                      onTap: () =>
                          setState(() => _selectedSubType = sub.id),
                      child: _Pill(
                          label: sub.label,
                          selected: _selectedSubType == sub.id),
                    ))
                .toList(),
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
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Titre (optionnel)',
              hintText: 'Ex : Premier mot',
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 16),
          _buildPhotoSection(),
          const SizedBox(height: 16),
          _buildVoiceMemoSection(),
          const SizedBox(height: 16),
          _buildLocationField(),
          const SizedBox(height: 16),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
              loadingLabel: _saveStatus,
              label:
                  _isEditing ? 'Mettre à jour' : 'Enregistrer ce souvenir',
              hint: _missingFieldsHint,
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
            children: cat.subTypes
                .map((sub) => GestureDetector(
                      onTap: () =>
                          setState(() => _selectedSubType = sub.id),
                      child: _Pill(
                          label: sub.label,
                          selected: _selectedSubType == sub.id),
                    ))
                .toList(),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Titre (optionnel)',
              hintText: 'Ex : Premiers pas !',
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Note (optionnel)',
              hintText: 'Ajoute un détail...',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          _buildPhotoSection(),
          const SizedBox(height: 16),
          _buildVoiceMemoSection(),
          const SizedBox(height: 16),
          _buildLocationField(),
          const SizedBox(height: 16),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
              loadingLabel: _saveStatus,
              label:
                  _isEditing ? 'Mettre à jour' : 'Enregistrer ce souvenir',
              hint: _missingFieldsHint,
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
    final birthdate = _notebook?.birthdate;
    final isEnfant = _notebook?.type == 'enfant';
    final ageAtDate = (isEnfant && birthdate != null)
        ? ((_selectedDate.year - birthdate.year) * 12 +
                _selectedDate.month -
                birthdate.month)
            .clamp(0, 24)
        : 0;
    final gender = _notebook?.gender ?? 'boy';
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
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
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
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
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
          if (isEnfant) ...[
            const SizedBox(height: 24),
            if (showWeight) ...[
              GrowthCurveChart(
                gender: gender,
                isWeight: true,
                ageMonths: ageAtDate,
                value: weightVal,
              ),
              const SizedBox(height: 20),
            ],
            if (showHeight) ...[
              GrowthCurveChart(
                gender: gender,
                isWeight: false,
                ageMonths: ageAtDate,
                value: heightVal,
              ),
              const SizedBox(height: 20),
            ],
            if (!showWeight && !showHeight) ...[
              GrowthCurveChart(
                gender: gender,
                isWeight: true,
                ageMonths: ageAtDate,
                value: null,
              ),
              const SizedBox(height: 20),
            ],
          ],
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Titre (optionnel)',
              hintText: 'Ex : Visite chez le pédiatre',
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 16),
          _buildPhotoSection(),
          const SizedBox(height: 16),
          _buildVoiceMemoSection(),
          const SizedBox(height: 16),
          _buildLocationField(),
          const SizedBox(height: 16),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
              loadingLabel: _saveStatus,
              label:
                  _isEditing ? 'Mettre à jour' : 'Enregistrer ce souvenir',
              hint: _missingFieldsHint,
              onPressed: _save),
        ],
      ),
    );
  }

  Widget _buildAnecdoteForm() {
    final cat =
        getMilestoneCategoryById(_selectedCategory ?? 'anecdote');
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('${cat.emoji} ${cat.label}'),
          if (cat.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(cat.description,
                style: const TextStyle(
                    color: AppColors.textMedium, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Titre (optionnel)',
              hintText: 'Ex : Premier pas dans la neige',
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textController,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Raconte ce moment…',
              hintText: 'Ajoute des détails, émotions, anecdotes…',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          _buildPhotoSection(),
          const SizedBox(height: 16),
          _buildVoiceMemoSection(),
          const SizedBox(height: 16),
          _buildLocationField(),
          const SizedBox(height: 16),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
              loadingLabel: _saveStatus,
              label:
                  _isEditing ? 'Mettre à jour' : 'Enregistrer ce souvenir',
              hint: _missingFieldsHint,
              onPressed: _save),
        ],
      ),
    );
  }

  // ── Photos widget (multi, scrollable row) ────────────────────────────────

  Widget _buildPhotoSection() {
    final totalCount = _existingPhotoUrls.length + _localPhotos.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (totalCount > 0) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (int i = 0; i < _existingPhotoUrls.length; i++)
                  _PhotoThumb(
                    child: Image.network(
                      _existingPhotoUrls[i],
                      width: 90, height: 90, fit: BoxFit.cover,
                      loadingBuilder: (_, child, p) => p == null ? child : Container(width: 90, height: 90, color: AppColors.background, child: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
                      errorBuilder: (_, __, ___) => Container(width: 90, height: 90, color: AppColors.background, child: const Icon(Icons.broken_image_outlined, color: AppColors.softGray)),
                    ),
                    onRemove: () => _removeExistingPhoto(_existingPhotoUrls[i]),
                  ),
                for (int i = 0; i < _localPhotos.length; i++)
                  _PhotoThumb(
                    child: Image.file(_localPhotos[i], width: 90, height: 90, fit: BoxFit.cover),
                    onRemove: () => _removeLocalPhoto(i),
                  ),
                GestureDetector(
                  onTap: _showPhotoSourceSheet,
                  child: Container(
                    width: 90, height: 90,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.sage, width: 1),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo_outlined, color: AppColors.sage, size: 22),
                        SizedBox(height: 4),
                        Text('Ajouter', style: TextStyle(fontSize: 10, color: AppColors.sage, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          GestureDetector(
            onTap: _showPhotoSourceSheet,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_photo_alternate_outlined, color: AppColors.sage, size: 20),
                  SizedBox(width: 8),
                  Text('Ajouter des photos', style: TextStyle(color: AppColors.sage, fontWeight: FontWeight.w600, fontSize: 14)),
                  SizedBox(width: 6),
                  Text('· galerie ou appareil', style: TextStyle(color: AppColors.softGray, fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ── Mémo vocal widget ─────────────────────────────────────────────────────

  Widget _buildVoiceMemoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('🎙️ Mémo vocal (optionnel)'),
        const SizedBox(height: 8),
        if (_hasAudio) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.sage, width: 1),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _togglePlayMemo,
                  child: Container(
                    width: 38, height: 38,
                    decoration: const BoxDecoration(
                      color: AppColors.sage,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isPlayingMemo ? Icons.stop : Icons.play_arrow,
                      color: Colors.white, size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Message vocal',
                          style: TextStyle(
                              color: AppColors.textDark,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                      if (_formatAudioDuration(_audioDurationMs).isNotEmpty)
                        Text(_formatAudioDuration(_audioDurationMs),
                            style: const TextStyle(
                                color: AppColors.textMedium, fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: AppColors.softGray, size: 22),
                  onPressed: _removeAudio,
                ),
              ],
            ),
          ),
        ] else ...[
          GestureDetector(
            onTap: _toggleRecording,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: _isRecording
                    ? AppColors.error.withOpacity(0.08)
                    : AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isRecording ? AppColors.error : const Color(0xFFDDD8CC),
                  width: _isRecording ? 1 : 0.5,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isRecording ? Icons.stop : Icons.mic_none_outlined,
                    color: _isRecording ? AppColors.error : AppColors.sage,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isRecording
                        ? 'Enregistrement… appuie pour arrêter'
                        : 'Enregistrer un message vocal',
                    style: TextStyle(
                      color: _isRecording ? AppColors.error : AppColors.sage,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Un QR code sera ajouté au livre pour écouter ce message.',
            style: TextStyle(color: AppColors.softGray, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildLocationField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('📍 Lieu'),
        const SizedBox(height: 8),
        TextField(
          controller: _locationController,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Ex : Zoo de Genève, Paris, Maison…',
          ),
        ),
      ],
    );
  }

  Widget _buildDateSection() {
    final minDate = _notebook?.birthdate ?? DateTime(2000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('📅 Date'),
        const SizedBox(height: 8),
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
          // Show current imprecise label + reset link
          GestureDetector(
            onTap: () => setState(() {
              _datePrecision = DatePrecision.exact;
              _dateNeedsConfirmation = true;
            }),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFFDDD8CC), width: 0.5),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_outlined,
                      size: 18, color: AppColors.textMedium),
                  const SizedBox(width: 10),
                  Text(_dateLabel,
                      style: const TextStyle(color: AppColors.textDark)),
                  const Spacer(),
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
            style: TextStyle(
                color: AppColors.textMedium,
                fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ── Shared widgets ───────────────────────────────────────────────────────────

class _PhotoThumb extends StatelessWidget {
  final Widget child;
  final VoidCallback onRemove;
  const _PhotoThumb({required this.child, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: child,
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
        borderRadius: BorderRadius.circular(50),
        border: Border.all(
          color: selected ? AppColors.sage : const Color(0xFFDDD8CC),
          width: selected ? 1.5 : 0.5,
        ),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color:
              highlighted ? const Color(0xFFFFF3CD) : AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: highlighted
                ? const Color(0xFFE6A817)
                : const Color(0xFFDDD8CC),
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
  final String? hint;
  final String? loadingLabel;
  final VoidCallback onPressed;

  const _SaveButton({
    required this.enabled,
    required this.loading,
    required this.label,
    required this.onPressed,
    this.hint,
    this.loadingLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (loadingLabel != null) ...[
              const SizedBox(height: 12),
              Text(
                loadingLabel!,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMedium,
                ),
              ),
            ],
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton(
          onPressed: enabled ? onPressed : null,
          style: ElevatedButton.styleFrom(
            disabledBackgroundColor: AppColors.background,
            disabledForegroundColor: AppColors.softGray,
          ),
          child: Text(label),
        ),
        if (!enabled && hint != null) ...[
          const SizedBox(height: 8),
          Text(
            hint!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.softGray,
            ),
          ),
        ],
      ],
    );
  }
}
