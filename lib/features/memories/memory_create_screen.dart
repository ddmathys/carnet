import 'dart:convert';
import 'dart:io';
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/models/notebook_model.dart';
import '../../core/services/media_upload_queue.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/quota_service.dart';
import '../../core/services/video_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/utils/date_precision.dart';
import '../../core/widgets/date_mask_field.dart';
import '../../core/widgets/media_fullscreen_viewer.dart';
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

  // Vidéos souvenir (jusqu'à maxVideosPerMemory clips, durée selon palier :
  // gratuit 2 min / premium 10 min, stockés sur R2).
  final List<String> _localVideoPaths = []; // nouvelles vidéos non uploadées
  final List<int?> _localVideoDurations = []; // parallèle à _localVideoPaths
  final List<String> _existingVideoKeys = []; // clés R2 conservées (édition)
  final List<int> _existingVideoDurations = []; // parallèle à _existingVideoKeys
  final List<String> _removedVideoKeys = []; // clés existantes supprimées
  bool _preparingVideo = false; // sélection/contrôle de durée en cours
  // Durée max par clip selon le palier (gratuit 2 min / premium 10 min).
  // Chargée en async au démarrage ; défaut prudent = palier gratuit.
  int _videoDurationCapSec = QuotaService.freeVideoDurationSec;

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

  // Photos (multi)
  final List<File> _localPhotos = [];
  final List<String> _existingPhotoUrls = [];
  final List<String> _removedPhotoUrls = [];
  // Photos R2 existantes : URL signée (affichée) → clé R2 (conservée en base).
  final Map<String, String> _existingKeyByUrl = {};
  final List<String> _removedPhotoKeys = [];
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _isEditing ? _loadForEdit() : _loadNotebook();
    _loadVideoDurationCap();
  }

  // Récupère la durée max autorisée par clip selon le palier de l'utilisateur.
  Future<void> _loadVideoDurationCap() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final cap = await QuotaService.getVideoDurationLimitSec(uid);
    if (mounted) setState(() => _videoDurationCapSec = cap);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _textController.dispose();
    _weightController.dispose();
    _heightController.dispose();
    _recorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  // Choix de type (étape 0) : uniquement pour la grossesse (étapes dédiées).
  // Partout ailleurs — y compris les carnets enfant — on va directement au
  // formulaire « souvenir » (texte libre), comme un carnet normal.
  bool get _hasTypePicker =>
      _notebook != null &&
      _notebook!.type != 'enfant' &&
      manualCategoriesForNotebook(_notebook!.type).isNotEmpty;

  Future<void> _loadNotebook() async {
    final doc = await FirebaseFirestore.instance
        .collection('notebooks')
        .doc(widget.notebookId)
        .get();
    if (mounted && doc.exists) {
      setState(() {
        _notebook = NotebookModel.fromFirestore(doc);
        // Pas de choix de type pour ce carnet → formulaire direct.
        if (!_hasTypePicker) {
          _selectedCategory = 'anecdote';
          _step = 1;
        }
      });
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

    // Photos R2 existantes : résoudre les URLs signées AVANT le setState (async).
    final mediaKeysData =
        List<String>.from(data['mediaKeys'] as List<dynamic>? ?? []);
    Map<String, String> signedMap = const {};
    if (mediaKeysData.isNotEmpty) {
      signedMap = await PhotoService.signedUrlsForMemory(widget.memoryId!);
      if (!mounted) return;
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
      // Photos R2 : affichées via URL signée, clé conservée pour la sauvegarde.
      for (final key in mediaKeysData) {
        final url = signedMap[key];
        if (url != null && url.isNotEmpty) {
          _existingPhotoUrls.add(url);
          _existingKeyByUrl[url] = key;
        }
      }
      _existingAudioUrl = data['audioUrl'] as String?;
      _audioDurationMs = (data['audioDurationMs'] as num?)?.toInt();
      // Vidéos (nouveau format multi, avec repli sur l'ancien videoKey unique).
      final videoKeys =
          List<String>.from(data['videoKeys'] as List<dynamic>? ?? []);
      final videoDurations = (data['videoDurationsMs'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          <int>[];
      if (videoKeys.isEmpty) {
        final legacyKey = data['videoKey'] as String?;
        if (legacyKey != null && legacyKey.isNotEmpty) {
          videoKeys.add(legacyKey);
          final legacyDur = (data['videoDurationMs'] as num?)?.toInt();
          if (legacyDur != null) videoDurations.add(legacyDur);
        }
      }
      _existingVideoKeys.addAll(videoKeys);
      _existingVideoDurations.addAll(videoDurations);
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
    // Quota photos : on bloque à la limite réelle (compte les photos déjà en
    // cours d'ajout). Premium = 10 000, gratuit = 350 (affiché 300).
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final q =
          await QuotaService.canAddPhotos(uid, adding: _localPhotos.length + 1);
      if (!q.allowed) {
        if (mounted) _showQuotaDialog();
        return;
      }
    }
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
      final key = _existingKeyByUrl.remove(url);
      if (key != null) {
        _removedPhotoKeys.add(key); // photo R2 → suppression par clé
      } else {
        _removedPhotoUrls.add(url); // ancienne photo Firebase → suppression par URL
      }
    });
  }

  void _removeLocalPhoto(int index) {
    setState(() => _localPhotos.removeAt(index));
  }

  void _showQuotaDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Limite de photos atteinte'),
        content: Text(
          'Le forfait gratuit est limité à ${QuotaService.freePhotoLimit} photos. '
          'Passe en premium pour ${QuotaService.premiumPhotoLimit} photos '
          '(${QuotaService.premiumPriceChf.toStringAsFixed(0)} CHF/an).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Plus tard'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push('/subscription');
            },
            child: const Text('Passer premium'),
          ),
        ],
      ),
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

    // Quota mémo vocal : on ne bloque que pour un NOUVEAU mémo (le
    // remplacement d'un audio déjà compté ne change pas le total).
    final replacingExisting = _localAudioPath != null ||
        (_existingAudioUrl != null && !_audioRemoved);
    if (!replacingExisting) {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        final q = await QuotaService.canAddAudios(uid);
        if (!q.allowed) {
          if (mounted) _showAudioQuotaDialog();
          return;
        }
      }
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

  // ── Vidéo souvenir ────────────────────────────────────────────────────────

  int get _videoCount => _existingVideoKeys.length + _localVideoPaths.length;
  bool get _hasVideo => _videoCount > 0;
  bool get _canAddVideo => _videoCount < QuotaService.maxVideosPerMemory;

  // Durée max par clip en texte lisible (ex. « 10 min », « 2 min », « 90 s »).
  String get _videoDurationLabel => _videoDurationCapSec % 60 == 0
      ? '${_videoDurationCapSec ~/ 60} min'
      : '$_videoDurationCapSec s';

  Future<void> _pickVideo(ImageSource source) async {
    // Limite par souvenir (max 3) — au-delà, on informe et on bloque.
    if (!_canAddVideo) {
      _showSnack(
          'Maximum ${QuotaService.maxVideosPerMemory} vidéos par souvenir.');
      return;
    }
    // Quota global (30 gratuit / 150 premium), en comptant les vidéos déjà
    // ajoutées localement dans ce souvenir.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final q = await QuotaService.canAddVideos(
          uid, adding: _localVideoPaths.length + 1);
      if (!q.allowed) {
        if (mounted) _showVideoQuotaDialog();
        return;
      }
    }
    setState(() => _preparingVideo = true);
    try {
      final picked = await _picker.pickVideo(
        source: source,
        maxDuration: Duration(seconds: _videoDurationCapSec),
      );
      if (picked == null) {
        if (mounted) setState(() => _preparingVideo = false);
        return;
      }
      final file = File(picked.path);

      // Cap de durée : `maxDuration` n'est pas garanti depuis la galerie selon
      // les plateformes → on revérifie. (best-effort, ne bloque jamais à tort).
      final durMs = await VideoService.probeDurationMs(file);
      if (durMs != null &&
          durMs > (_videoDurationCapSec + 5) * 1000) {
        if (mounted) {
          setState(() => _preparingVideo = false);
          _showSnack('Vidéo trop longue (max $_videoDurationLabel).');
        }
        return;
      }

      if (mounted) {
        setState(() {
          _localVideoPaths.add(picked.path);
          _localVideoDurations.add(durMs);
          _preparingVideo = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _preparingVideo = false);
        _showSnack('Impossible d\'accéder à la vidéo');
      }
    }
  }

  bool _isVideoPath(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.mp4') ||
        p.endsWith('.mov') ||
        p.endsWith('.m4v') ||
        p.endsWith('.avi') ||
        p.endsWith('.mkv') ||
        p.endsWith('.webm') ||
        p.endsWith('.3gp') ||
        p.endsWith('.hevc');
  }

  /// Ingère une liste de chemins vidéo : plafond par souvenir (max 3), quota
  /// global (gratuit/premium) et cap de durée. Ce qui est refusé est signalé
  /// sans bloquer le reste. Utilisé par l'import unifié galerie.
  Future<void> _ingestVideoPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final remaining = QuotaService.maxVideosPerMemory - _videoCount;
    if (remaining <= 0) {
      _showSnack(
          'Maximum ${QuotaService.maxVideosPerMemory} vidéos par souvenir.');
      return;
    }
    // Vidéos au-delà du plafond du souvenir → ignorées.
    final ignoredForLimit =
        paths.length > remaining ? paths.length - remaining : 0;
    final toConsider = paths.take(remaining).toList();

    final uid = FirebaseAuth.instance.currentUser?.uid;
    final accepted = <String>[];
    final acceptedDurations = <int?>[];
    int tooLong = 0;
    bool quotaHit = false;

    for (final path in toConsider) {
      // Quota global, réévalué à chaque ajout (gratuit 30 / premium 150).
      if (uid != null) {
        final q = await QuotaService.canAddVideos(
            uid, adding: _localVideoPaths.length + accepted.length + 1);
        if (!q.allowed) {
          quotaHit = true;
          break;
        }
      }
      final durMs = await VideoService.probeDurationMs(File(path));
      if (durMs != null &&
          durMs > (_videoDurationCapSec + 5) * 1000) {
        tooLong++;
        continue;
      }
      accepted.add(path);
      acceptedDurations.add(durMs);
    }

    if (!mounted) return;
    setState(() {
      _localVideoPaths.addAll(accepted);
      _localVideoDurations.addAll(acceptedDurations);
    });

    if (quotaHit) {
      _showVideoQuotaDialog();
      return;
    }
    final notes = <String>[];
    if (tooLong > 0) {
      notes.add('$tooLong trop longue${tooLong > 1 ? 's' : ''} '
          '(max $_videoDurationLabel)');
    }
    if (ignoredForLimit > 0) {
      notes.add('$ignoredForLimit au-delà de '
          '${QuotaService.maxVideosPerMemory} vidéos');
    }
    if (notes.isNotEmpty) _showSnack('Ignoré : ${notes.join(' · ')}.');
  }

  /// Import unifié depuis la galerie : photos ET vidéos en une seule sélection
  /// (Android Photo Picker via `pickMultipleMedia`), puis répartition vers les
  /// deux pipelines (photos → EXIF, vidéos → cap durée). Aucun changement côté
  /// enregistrement : chaque média garde son flux d'origine.
  Future<void> _pickMediaFromGallery() async {
    setState(() => _preparingVideo = true);
    try {
      final picked =
          await _picker.pickMultipleMedia(imageQuality: 80, maxWidth: 1920);
      if (picked.isEmpty) {
        if (mounted) setState(() => _preparingVideo = false);
        return;
      }
      final photoFiles = <File>[];
      final videoPaths = <String>[];
      for (final x in picked) {
        if (_isVideoPath(x.path)) {
          videoPaths.add(x.path);
        } else {
          photoFiles.add(File(x.path));
        }
      }

      // 1) Photos — quota global photos, puis EXIF (date + lieu) de la 1ʳᵉ.
      if (photoFiles.isNotEmpty) {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        bool photoOk = true;
        if (uid != null) {
          final q = await QuotaService.canAddPhotos(
              uid, adding: _localPhotos.length + photoFiles.length);
          photoOk = q.allowed;
        }
        if (photoOk) {
          if (mounted) setState(() => _localPhotos.addAll(photoFiles));
          await _applyExifFromPhoto(photoFiles.first);
        } else if (mounted) {
          _showQuotaDialog();
        }
      }

      // 2) Vidéos — plafond souvenir + quota + durée.
      await _ingestVideoPaths(videoPaths);
    } catch (_) {
      if (mounted) _showSnack('Impossible d\'accéder aux médias');
    } finally {
      if (mounted) setState(() => _preparingVideo = false);
    }
  }

  void _removeLocalVideo(int index) {
    setState(() {
      _localVideoPaths.removeAt(index);
      _localVideoDurations.removeAt(index);
    });
  }

  void _removeExistingVideo(int index) {
    setState(() {
      _removedVideoKeys.add(_existingVideoKeys[index]);
      _existingVideoKeys.removeAt(index);
      if (index < _existingVideoDurations.length) {
        _existingVideoDurations.removeAt(index);
      }
    });
  }

  // Ouvre la galerie plein écran sur les photos (existantes + locales), centrée
  // sur la vignette touchée. Ordre identique à l'affichage des vignettes.
  void _openPhotoViewer(int index) {
    final items = <FullscreenMedia>[
      for (final url in _existingPhotoUrls) FullscreenMedia.photoUrl(url),
      for (final f in _localPhotos) FullscreenMedia.photoFile(f),
    ];
    MediaFullscreenViewer.open(context, items: items, initialIndex: index);
  }

  // Idem pour les vidéos. Les clés R2 des vidéos existantes sont résolues en URLs
  // publiques avant ouverture ; les vidéos locales jouent depuis le fichier.
  Future<void> _openVideoViewer(int index) async {
    // Les vidéos déjà uploadées (édition) sont servies via des URLs signées
    // délivrées par le backend après contrôle d'accès au carnet ; les vidéos
    // locales pas encore uploadées se lisent depuis le fichier.
    Map<String, String> resolved = const {};
    if (_existingVideoKeys.isNotEmpty && widget.memoryId != null) {
      resolved = await VideoService.playbackUrls(widget.memoryId!);
    }
    if (!mounted) return;
    final items = <FullscreenMedia>[
      for (final key in _existingVideoKeys)
        FullscreenMedia.videoUrl(resolved[key]),
      for (final p in _localVideoPaths) FullscreenMedia.videoFile(p),
    ];
    MediaFullscreenViewer.open(context, items: items, initialIndex: index);
  }

  void _showVideoQuotaDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Limite de vidéos atteinte'),
        content: Text(
          'Le forfait gratuit est limité à ${QuotaService.freeVideoLimit} vidéos. '
          'Passe en premium pour ${QuotaService.premiumVideoLimit} vidéos '
          '(${QuotaService.premiumPriceChf.toStringAsFixed(0)} CHF/an).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Plus tard'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push('/subscription');
            },
            child: const Text('Passer premium'),
          ),
        ],
      ),
    );
  }

  void _showAudioQuotaDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Limite de mémos vocaux atteinte'),
        content: Text(
          'Le forfait gratuit est limité à ${QuotaService.freeAudioLimit} mémos vocaux. '
          'Passe en premium pour ${QuotaService.premiumAudioLimit} mémos '
          '(${QuotaService.premiumPriceChf.toStringAsFixed(0)} CHF/an).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Plus tard'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push('/subscription');
            },
            child: const Text('Passer premium'),
          ),
        ],
      ),
    );
  }

  /// Feuille d'import unique : galerie (photos + vidéos en une fois), ou prise
  /// directe photo / vidéo. Remplace les deux anciennes feuilles séparées.
  Future<void> _showMediaSourceSheet() async {
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
              leading: const Icon(Icons.perm_media_outlined, color: AppColors.sage),
              title: const Text('Choisir dans la galerie'),
              subtitle: const Text('Photos et vidéos, sélection multiple'),
              onTap: () {
                Navigator.pop(context);
                _pickMediaFromGallery();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_a_photo_outlined, color: AppColors.sage),
              title: const Text('Prendre une photo'),
              onTap: () {
                Navigator.pop(context);
                _pickPhotos(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined, color: AppColors.sage),
              title: const Text('Filmer une vidéo'),
              subtitle: const Text('2 minutes max'),
              onTap: () {
                Navigator.pop(context);
                _pickVideo(ImageSource.camera);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
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


  String? get _missingFieldsHint {
    final missing = <String>[];
    if (_titleRequiredEmpty) missing.add('titre');
    if (_dateNeedsConfirmation) missing.add('date');
    if (_locationRequiredEmpty) missing.add('lieu');
    switch (_selectedCategory) {
      case 'parole':
      case 'mouvement':
        if (_selectedSubType == null) missing.add('type précis');
        break;
      case 'taille_poids':
        if (_measurementMissing) missing.add('taille ou poids');
        break;
      case 'anecdote':
      case null:
        if (_textController.text.trim().isEmpty) missing.add('description');
        break;
      default:
        break;
    }
    if (missing.isEmpty) return null;
    return 'Champs obligatoires : ${missing.join(', ')}';
  }

  // ── Validation des champs obligatoires ───────────────────────────────────
  // Requis : titre + lieu + date confirmée + un contenu selon le type. Une
  // catégorie nulle (« Autre souvenir ») est traitée comme « anecdote ».
  bool get _measurementMissing {
    final w = double.tryParse(_weightController.text.replaceAll(',', '.'));
    final h = double.tryParse(_heightController.text.replaceAll(',', '.'));
    return !((w != null && w > 0) || (h != null && h > 0));
  }

  bool get _titleRequiredEmpty => _titleController.text.trim().isEmpty;
  bool get _locationRequiredEmpty => _locationController.text.trim().isEmpty;

  bool get _descriptionRequiredEmpty =>
      (_selectedCategory == 'anecdote' || _selectedCategory == null) &&
      _textController.text.trim().isEmpty;

  // Bordure rouge pour les champs obligatoires non remplis.
  OutlineInputBorder get _errorBorder => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.error, width: 1.5),
      );

  bool get _saveEnabled {
    if (_titleRequiredEmpty || _locationRequiredEmpty) return false;
    if (_dateNeedsConfirmation) return false;
    switch (_selectedCategory) {
      case 'parole':
      case 'mouvement':
        return _selectedSubType != null;
      case 'taille_poids':
        return !_measurementMissing;
      case 'anecdote':
      case null:
        return _textController.text.trim().isNotEmpty;
      default:
        return true;
    }
  }

  Future<void> _save() async {
    if (!_saveEnabled || _loading) return;
    setState(() => _loading = true);
    try {
      // Catégorie nulle (repli manuel après échec/timeout IA) → « anecdote ».
      final category = _selectedCategory ?? 'anecdote';
      final rawContent = _buildRawContent(category);
      final weightKg = category == 'taille_poids'
          ? double.tryParse(_weightController.text.replaceAll(',', '.'))
          : null;
      final heightCm = category == 'taille_poids'
          ? double.tryParse(_heightController.text.replaceAll(',', '.'))
          : null;

      // ── Sauvegarde optimiste (façon WhatsApp) ─────────────────────────────
      // On écrit d'abord le souvenir en base AVEC les médias déjà connus
      // (photos existantes en édition, audio existant conservé). Les NOUVEAUX
      // médias (photos locales, mémo vocal fraîchement enregistré) sont laissés
      // de côté : ils partent en arrière-plan via MediaUploadQueue, qui
      // complétera le document une fois l'upload terminé. La liste écoute le
      // flux Firestore en temps réel → le souvenir apparaît tout de suite et
      // ses photos arrivent toutes seules ensuite.
      // `_existingPhotoUrls` mélange d'anciennes URLs Firebase et des URLs R2
      // signées (temporaires) → on sépare : les URLs signées ne doivent jamais
      // être écrites en base, seule leur CLÉ R2 (via `_existingKeyByUrl`) l'est.
      final keptLegacyUrls = [
        for (final u in _existingPhotoUrls)
          if (!_existingKeyByUrl.containsKey(u)) u
      ];
      final keptPhotoKeys = [
        for (final u in _existingPhotoUrls)
          if (_existingKeyByUrl.containsKey(u)) _existingKeyByUrl[u]!
      ];
      final knownAudioUrl = _audioRemoved ? null : _existingAudioUrl;
      // Vidéos déjà uploadées et conservées (les nouvelles partent en file).
      final knownVideoKeys = List<String>.of(_existingVideoKeys);
      final knownVideoDurations = List<int>.of(_existingVideoDurations);

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
        'mediaUrls': keptLegacyUrls,
        'mediaKeys': keptPhotoKeys,
        'photoUrl': keptLegacyUrls.isNotEmpty ? keptLegacyUrls.first : null,
        'audioUrl': knownAudioUrl,
        'audioDurationMs': knownAudioUrl != null ? _audioDurationMs : null,
        'videoKeys': knownVideoKeys,
        'videoDurationsMs': knownVideoDurations,
        // Miroir hérité (compat anciens lecteurs / page /watch d'origine).
        'videoKey': knownVideoKeys.isNotEmpty ? knownVideoKeys.first : null,
        'videoDurationMs':
            knownVideoDurations.isNotEmpty ? knownVideoDurations.first : null,
        'weightKg': weightKg,
        'heightCm': heightCm,
      };

      final col = FirebaseFirestore.instance.collection('memories');
      final String memoryId;
      if (_isEditing) {
        memoryId = widget.memoryId!;
        await col.doc(memoryId).update(payload);
      } else {
        // doc() génère l'id côté client → pas besoin d'attendre le serveur.
        final ref = col.doc();
        memoryId = ref.id;
        await ref.set({
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

      // Y a-t-il des médias à uploader/supprimer en arrière-plan ?
      final hasMediaWork = _localPhotos.isNotEmpty ||
          _localAudioPath != null ||
          _localVideoPaths.isNotEmpty ||
          _removedPhotoUrls.isNotEmpty ||
          _removedPhotoKeys.isNotEmpty ||
          _removedVideoKeys.isNotEmpty ||
          (_audioRemoved && _existingAudioUrl != null);
      if (hasMediaWork) {
        MediaUploadQueue.instance.enqueue(MediaUploadJob(
          memoryId: memoryId,
          notebookId: widget.notebookId,
          localPhotos: List<File>.of(_localPhotos),
          existingPhotoUrls: keptLegacyUrls,
          existingPhotoKeys: keptPhotoKeys,
          removedPhotoUrls: List<String>.of(_removedPhotoUrls),
          removedPhotoKeys: List<String>.of(_removedPhotoKeys),
          localAudioPath: _localAudioPath,
          existingAudioUrl: _existingAudioUrl,
          audioRemoved: _audioRemoved,
          audioDurationMs: _audioDurationMs,
          localVideoPaths: List<String>.of(_localVideoPaths),
          localVideoDurations: List<int?>.of(_localVideoDurations),
          existingVideoKeys: knownVideoKeys,
          existingVideoDurations: knownVideoDurations,
          removedVideoKeys: List<String>.of(_removedVideoKeys),
        ));
      }

      if (mounted) context.go('/notebook/${widget.notebookId}/memories');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showSnack(_friendlyError(e));
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
    // Retour vers le choix de type seulement si ce carnet en propose un et
    // qu'on n'est pas en édition. Sinon, on quitte vers la liste.
    if (_step == 1 && _hasTypePicker && !_isEditing) {
      setState(() {
        _step = 0;
        _selectedCategory = null;
        _selectedSubType = null;
        _dateNeedsConfirmation = true;
        _textController.clear();
        _weightController.clear();
        _heightController.clear();
      });
    } else {
      context.go('/notebook/${widget.notebookId}/memories');
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
          _isEditing ? 'Modifier le souvenir' : 'Nouveau souvenir',
          style: const TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontWeight: FontWeight.bold,
              color: AppColors.textDark),
        ),
        leading: IconButton(
          icon: Icon(
            (_step == 0 || (!_hasTypePicker && !_isEditing))
                ? Icons.close
                : Icons.arrow_back,
            color: AppColors.textDark,
          ),
          onPressed: _goBack,
        ),
      ),
      body: _step == 0 ? _buildTypePickerStep() : _buildDetailsStep(),
    );
  }

  /// Étape de choix du type — affichée uniquement pour les carnets bébé /
  /// grossesse. Les autres carnets vont directement au formulaire « souvenir ».
  Widget _buildTypePickerStep() {
    final manualCats = manualCategoriesForNotebook(_notebook!.type);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quel souvenir veux-tu ajouter ?',
            style: TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Choisis un type, ou « Autre souvenir » pour écrire librement.',
            style: TextStyle(color: AppColors.textMedium, fontSize: 14),
          ),
          const SizedBox(height: 20),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: 1.3,
            children: manualCats.map((cat) {
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
                        color: AppColors.border, width: 0.5),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(cat.emoji, style: const TextStyle(fontSize: 32)),
                      const SizedBox(height: 6),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          cat.label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDark,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton.icon(
              onPressed: () => setState(() {
                _selectedCategory = 'anecdote';
                _step = 1;
              }),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Autre souvenir'),
              style: TextButton.styleFrom(foregroundColor: AppColors.sage),
            ),
          ),
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
          _SectionTitle('💬 Type de parole', error: _selectedSubType == null),
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
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Titre',
              hintText: 'Ex : Premier mot',
              enabledBorder: _titleRequiredEmpty ? _errorBorder : null,
              focusedBorder: _titleRequiredEmpty ? _errorBorder : null,
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 16),
          _buildPhotoSection(),
          const SizedBox(height: 16),
          _buildVoiceMemoSection(),
          const SizedBox(height: 16),
          _buildVideoSection(),
          const SizedBox(height: 16),
          _buildLocationField(),
          const SizedBox(height: 16),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
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
          _SectionTitle('🏃 Type de mouvement',
              error: _selectedSubType == null),
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
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Titre',
              hintText: 'Ex : Premiers pas !',
              enabledBorder: _titleRequiredEmpty ? _errorBorder : null,
              focusedBorder: _titleRequiredEmpty ? _errorBorder : null,
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
          _buildVideoSection(),
          const SizedBox(height: 16),
          _buildLocationField(),
          const SizedBox(height: 16),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
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
          _SectionTitle('📊 Mesures', error: _measurementMissing),
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
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Titre',
              hintText: 'Ex : Visite chez le pédiatre',
              enabledBorder: _titleRequiredEmpty ? _errorBorder : null,
              focusedBorder: _titleRequiredEmpty ? _errorBorder : null,
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 16),
          _buildPhotoSection(),
          const SizedBox(height: 16),
          _buildVoiceMemoSection(),
          const SizedBox(height: 16),
          _buildVideoSection(),
          const SizedBox(height: 16),
          _buildLocationField(),
          const SizedBox(height: 16),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
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
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Titre',
              hintText: 'Ex : Premier pas dans la neige',
              enabledBorder: _titleRequiredEmpty ? _errorBorder : null,
              focusedBorder: _titleRequiredEmpty ? _errorBorder : null,
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textController,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: 'Qu\'est-ce qui t\'a marqué pour ce souvenir ?',
              hintText: 'Partage-le ici…',
              alignLabelWithHint: true,
              // Encadré rouge tant que la description (obligatoire ici) est vide.
              enabledBorder: _descriptionRequiredEmpty ? _errorBorder : null,
              focusedBorder: _descriptionRequiredEmpty ? _errorBorder : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          _buildPhotoSection(),
          const SizedBox(height: 16),
          _buildVoiceMemoSection(),
          const SizedBox(height: 16),
          _buildVideoSection(),
          const SizedBox(height: 16),
          _buildLocationField(),
          const SizedBox(height: 16),
          _buildDateSection(),
          const SizedBox(height: 28),
          _SaveButton(
              enabled: _saveEnabled,
              loading: _loading,
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
                    onTap: () => _openPhotoViewer(i),
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
                    onTap: () =>
                        _openPhotoViewer(_existingPhotoUrls.length + i),
                    child: Image.file(_localPhotos[i], width: 90, height: 90, fit: BoxFit.cover),
                    onRemove: () => _removeLocalPhoto(i),
                  ),
                GestureDetector(
                  onTap: _showMediaSourceSheet,
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
            onTap: _showMediaSourceSheet,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border, width: 0.5),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_photo_alternate_outlined, color: AppColors.sage, size: 20),
                  SizedBox(width: 8),
                  Text('Ajouter photos & vidéos', style: TextStyle(color: AppColors.sage, fontWeight: FontWeight.w600, fontSize: 14)),
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
                  color: _isRecording ? AppColors.error : AppColors.border,
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

  // ── Vidéo widget ──────────────────────────────────────────────────────────

  /// Affichage seul des vidéos du souvenir : l'ajout passe désormais par le
  /// bouton unique « Ajouter photos & vidéos » (galerie mixte). Masqué tant
  /// qu'aucune vidéo n'est présente et qu'aucun import n'est en cours.
  Widget _buildVideoSection() {
    if (!_hasVideo && !_preparingVideo) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
            '🎬 Vidéos (optionnel · ${QuotaService.maxVideosPerMemory} max)'),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (int i = 0; i < _existingVideoKeys.length; i++)
                _VideoThumb(
                  durationLabel: i < _existingVideoDurations.length
                      ? _formatAudioDuration(_existingVideoDurations[i])
                      : '',
                  onTap: () => _openVideoViewer(i),
                  onRemove: () => _removeExistingVideo(i),
                ),
              for (int i = 0; i < _localVideoPaths.length; i++)
                _VideoThumb(
                  durationLabel: _formatAudioDuration(_localVideoDurations[i]),
                  onTap: () => _openVideoViewer(_existingVideoKeys.length + i),
                  onRemove: () => _removeLocalVideo(i),
                ),
              if (_preparingVideo)
                Container(
                  width: 90, height: 90,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: AppColors.border, width: 0.5),
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.sage),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Jusqu\'à ${QuotaService.maxVideosPerMemory} vidéos de '
          '$_videoDurationLabel. Un QR code dans le livre '
          'mène à toutes les vidéos du souvenir.',
          style: const TextStyle(color: AppColors.softGray, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildLocationField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('📍 Lieu', error: _locationRequiredEmpty),
        const SizedBox(height: 8),
        TextField(
          controller: _locationController,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Ex : Zoo de Genève, Paris, Maison…',
            enabledBorder: _locationRequiredEmpty ? _errorBorder : null,
            focusedBorder: _locationRequiredEmpty ? _errorBorder : null,
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
        _SectionTitle('📅 Date', error: _dateNeedsConfirmation),
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
                    color: AppColors.border, width: 0.5),
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
  final VoidCallback? onTap;
  const _PhotoThumb({required this.child, required this.onRemove, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      child: Stack(
        children: [
          GestureDetector(
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: child,
            ),
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

/// Vignette d'une vidéo dans l'écran de création (carte sombre + ▶ + durée).
/// On n'extrait pas de miniature réelle (coûteux) : un visuel cohérent suffit.
class _VideoThumb extends StatelessWidget {
  final String durationLabel;
  final VoidCallback onRemove;
  final VoidCallback? onTap;
  const _VideoThumb(
      {required this.durationLabel, required this.onRemove, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      child: Stack(
        children: [
          GestureDetector(
            onTap: onTap,
            child: Container(
              width: 90, height: 90,
              decoration: BoxDecoration(
                color: const Color(0xFF2D2D2D),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Center(
                child: Icon(Icons.play_circle_outline,
                    color: Colors.white, size: 32),
              ),
            ),
          ),
          if (durationLabel.isNotEmpty)
            Positioned(
              bottom: 4,
              left: 4,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(durationLabel,
                    style: const TextStyle(color: Colors.white, fontSize: 10)),
              ),
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
  // [error] = champ obligatoire non rempli → titre en rouge + mention.
  final bool error;
  const _SectionTitle(this.text, {this.error = false});

  @override
  Widget build(BuildContext context) => Text(
        error ? '$text — obligatoire' : text,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: error ? AppColors.error : AppColors.textDark,
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
          color: selected ? AppColors.sage : AppColors.border,
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

class _SaveButton extends StatelessWidget {
  final bool enabled;
  final bool loading;
  final String label;
  final String? hint;
  final VoidCallback onPressed;

  const _SaveButton({
    required this.enabled,
    required this.loading,
    required this.label,
    required this.onPressed,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
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
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  size: 14, color: AppColors.error),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.error,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
