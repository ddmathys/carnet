import 'dart:async';
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/models/poster_template.dart';
import '../../core/services/backend_client.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/pdf_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/poster_format_rules.dart';
import '../../core/services/poster_pdf_service.dart';
import '../../core/services/poster_pricing.dart';
import '../../core/services/poster_quality_service.dart';
import '../../core/utils/image_dims.dart';

/// Génération d'un tirage à accrocher ("Art print with hanger" chez Prodigi)
/// à partir des photos choisies à l'écran précédent
/// (poster_select_screen.dart). Équivalent poster de BookGenerateScreen, en
/// beaucoup plus court : une seule page, un petit catalogue de tailles fixes
/// (voir poster_pricing.dart). Noms de code internes (fichiers, routes,
/// champs Firestore) gardés "poster" — seul le texte affiché à l'utilisateur
/// dit "tirage à accrocher".
class PosterGenerateScreen extends StatefulWidget {
  /// Une entrée par PHOTO choisie (pas par souvenir — un souvenir peut en
  /// fournir plusieurs, voir poster_select_screen.dart).
  final List<({String memoryId, int photoIndex})> photoRefs;
  final String? editOrderId;
  const PosterGenerateScreen({
    super.key,
    this.photoRefs = const [],
    this.editOrderId,
  });

  @override
  State<PosterGenerateScreen> createState() => _PosterGenerateScreenState();
}

class _PosterGenerateScreenState extends State<PosterGenerateScreen> {
  int _step = 0; // 0 = collage, 1 = taille/couleur, 2 = adresse/commande

  // Souvenirs DISTINCTS parmi les photos choisies — sert au "reel" vidéo
  // (QR code) et au décompte affiché, pas au collage lui-même.
  List<MemoryModel> _uniqueMemories = [];
  List<String> _photoUrls = [];
  List<Uint8List> _photoBytes = [];
  List<({int w, int h})?> _photoDims = [];
  final Set<int> _featured = {};
  // Photo désignée par PosterQualityService comme responsable du blocage
  // qualité d'une taille tapée par l'utilisateur — mise en évidence dans
  // l'aperçu du collage (étape 0) le temps qu'il/elle agisse dessus.
  int? _bottleneckIndex;

  String _size = 'A4';
  String _color = 'natural';
  final _captionCtrl = TextEditingController();

  bool _loading = true;
  String? _loadError;
  bool _ordering = false;
  String _orderMessage = '';

  final _addressKey = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _streetCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _npaCtrl = TextEditingController();
  final _countryCtrl = TextEditingController(text: 'Suisse');

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _streetCtrl.dispose();
    _cityCtrl.dispose();
    _npaCtrl.dispose();
    _countryCtrl.dispose();
    super.dispose();
  }

  PosterLayout get _layout => buildPosterLayout(_photoUrls.length, _featured);

  Map<String, PosterSizeQuality> get _quality =>
      PosterQualityService.evaluateAll(layout: _layout, photoDims: _photoDims);

  /// Format papier minimum imposé par le collage courant (nombre de photos ET
  /// mises en avant) — voir poster_format_rules.dart.
  String get _minSize => PosterFormatRules.minSizeFor(_layout);

  List<String> get _allowedSizes => PosterFormatRules.allowedSizes(_layout);

  /// Vrai si au moins un des souvenirs choisis a une vidéo ou un mémo vocal —
  /// seul cas où le QR (lien vers le "reel") a une destination réelle. Un
  /// tirage 100% photos n'imprime pas de QR mort. `audioKey` seulement (pas
  /// l'ancien `audioUrl` Firebase) : même convention que le backend
  /// (`audioKeyOf` dans lib/access.ts), pour que ce que promet le QR soit
  /// toujours ce que le reel peut effectivement servir.
  bool get _hasMedia =>
      _uniqueMemories.any((m) => m.videoKeys.isNotEmpty || m.audioKey != null);

  /// À appeler (dans un setState) après TOUT changement du collage : si la
  /// taille choisie est devenue trop petite pour le nombre de cases, on
  /// remonte au minimum imposé. On ne redescend jamais une taille plus grande
  /// choisie exprès.
  void _syncSizeToLayout() {
    final sizes = _allowedSizes;
    if (!sizes.contains(_size)) _size = sizes.first;
  }

  Future<void> _loadData() async {
    setState(() => _loadError = null);
    try {
      final visible = await MemoryQueryService.visible()
          .first
          .timeout(const Duration(seconds: 20));
      final byId = {for (final m in visible) m.id: m};

      var refs = [
        for (final r in widget.photoRefs) if (byId.containsKey(r.memoryId)) r,
      ];
      if (refs.isEmpty) {
        setState(() {
          _loadError = 'Aucune photo sélectionnée pour ce tirage.';
          _loading = false;
        });
        return;
      }
      if (refs.length > posterMaxPhotos) {
        refs = refs.sublist(0, posterMaxPhotos);
      }

      // Résout les photos de chaque souvenir DISTINCT une seule fois
      // (PhotoService met déjà en cache par souvenir), puis pioche l'index
      // demandé pour chaque photo choisie, dans l'ordre de sélection.
      final uniqueIds = {for (final r in refs) r.memoryId};
      final urlsByMemory = <String, List<String>>{};
      for (final id in uniqueIds) {
        urlsByMemory[id] = await PhotoService.resolvePhotoUrls(byId[id]!);
      }

      final urls = <String>[];
      for (final r in refs) {
        final list = urlsByMemory[r.memoryId] ?? const [];
        if (r.photoIndex < 0 || r.photoIndex >= list.length) continue;
        urls.add(list[r.photoIndex]);
      }
      if (urls.isEmpty) {
        setState(() {
          _loadError = 'Aucune photo exploitable dans cette sélection.';
          _loading = false;
        });
        return;
      }

      final bytes = await PosterPdfService.downloadPhotoBytes(urls);
      final dims = [for (final b in bytes) imageDims(b)];

      if (!mounted) return;
      setState(() {
        _uniqueMemories = [for (final id in uniqueIds) byId[id]!];
        _photoUrls = urls;
        _photoBytes = bytes;
        _photoDims = dims;
        // Une photo en avant par défaut UNIQUEMENT sur les gabarits fixes
        // (2-4 photos) : c'est aussi ce qui rend la fonction visible (l'étoile
        // apparaît sur la première photo, le texte au-dessus explique comment
        // en changer). À partir de 5 photos (mosaïque), pas de vedette par
        // défaut — avec beaucoup de vignettes, une case agrandie qu'on n'a pas
        // choisie est difficile à repérer/désactiver, et peut à elle seule
        // bloquer les grands formats si sa résolution est trop juste (voir
        // PosterQualityService.bottleneckPhotoIndex).
        if (urls.length > 1 && urls.length <= 4) _featured.add(0);
        _syncSizeToLayout();
        _loading = false;
      });

      if (widget.editOrderId != null) await _loadEditOrderDefaults();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _loadEditOrderDefaults() async {
    try {
      final order = await OrderService.getOrder(widget.editOrderId!)
          .timeout(const Duration(seconds: 10));
      if (order == null || !mounted) return;
      setState(() {
        if (order.posterSize != null) _size = order.posterSize!;
        if (order.posterHangerColor != null) _color = order.posterHangerColor!;
        // Une ancienne commande peut porter une taille devenue trop petite
        // pour ce collage : on la remonte plutôt que de la laisser bloquer.
        _syncSizeToLayout();
        _firstNameCtrl.text = order.firstName;
        _lastNameCtrl.text = order.lastName;
        _streetCtrl.text = order.street;
        _cityCtrl.text = order.city;
        _npaCtrl.text = order.npa;
        _countryCtrl.text = order.country;
      });
      _captionCtrl.text = order.posterCaption ?? '';
    } catch (_) {
      // Pas grave : les champs restent à saisir à la main.
    }
  }

  void _toggleFeatured(int i) {
    setState(() {
      if (_photoUrls.length <= 4) {
        // 1-4 photos : la vedette change le template (voir poster_template.dart)
        // — un seul choix à la fois pour rester dans le petit catalogue de
        // templates prévu.
        if (!_featured.remove(i)) {
          _featured
            ..clear()
            ..add(i);
        }
      } else if (!_featured.remove(i)) {
        // 5 photos et plus : autant de photos en avant qu'on veut, chacune
        // occupe un bloc 2×2 dans la mosaïque.
        _featured.add(i);
      }
      // Une vedette de plus = des cases plus petites pour les autres, donc
      // parfois un format minimum plus grand.
      _syncSizeToLayout();
      // Le collage a changé : l'ancien repère qualité peut ne plus s'appliquer.
      _bottleneckIndex = null;
    });
  }

  String get _orientation =>
      _layout.orientation == PosterOrientation.landscape ? 'landscape' : 'portrait';

  /// Valide `_size` pour le collage courant — les deux règles
  /// (PosterFormatRules = format minimum lisible, PosterQualityService =
  /// format maximum net vu la résolution des photos) peuvent se contredire
  /// sur un collage dense/très featuré : le format minimum imposé peut être
  /// justement celui que la qualité interdit. Appelée dès la sortie de
  /// l'étape Taille (pas seulement à la commande) pour ne pas laisser
  /// l'utilisateur remplir toute l'adresse avant de découvrir le problème.
  String? _sizeValidationError() {
    if (PosterFormatRules.isTooSmall(_layout, _size)) {
      return 'Avec ${_photoUrls.length} photos, le format minimum est $_minSize.';
    }
    final quality = _quality[_size];
    if (quality == null || quality.verdict == PosterQualityVerdict.disabled) {
      // Si _size est déjà le plus petit format imposé par le collage
      // (_allowedSizes est trié du plus petit au plus grand, et la qualité ne
      // peut que se dégrader avec la taille), aucun format du catalogue ne
      // conviendra : le vrai problème est le collage, pas le choix de taille.
      final allowed = _allowedSizes;
      final isSmallestAllowed = allowed.isNotEmpty && allowed.first == _size;
      if (isSmallestAllowed) {
        return 'Aucun format n\'est assez net pour ce collage avec ces photos — retire des photos ou réduis le nombre de photos mises en avant, puis réessaie.';
      }
      return 'Cette taille n\'est pas assez nette avec ces photos — choisis une taille plus petite.';
    }
    return null;
  }

  Future<void> _placeOrder() async {
    final sizeError = _sizeValidationError();
    if (sizeError != null) {
      _showSnack(sizeError);
      return;
    }
    final isEdit = widget.editOrderId != null;
    if (!isEdit && !(_addressKey.currentState?.validate() ?? false)) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final hasMedia = _hasMedia;
    setState(() {
      _ordering = true;
      _orderMessage = hasMedia ? 'Préparation des vidéos liées…' : 'Génération du tirage…';
    });
    try {
      // 1. "Reel" vidéo public (cible du QR) — créé AVANT le PDF puisque le QR
      // doit déjà être imprimé dedans. Seulement si au moins un souvenir a une
      // vidéo/mémo vocal : sinon pas de QR à imprimer (voir _hasMedia).
      String? qrUrl;
      if (hasMedia) {
        final reelRes = await BackendClient.postJson(
          '/api/video/poster-reel-create',
          {'memoryIds': _uniqueMemories.map((m) => m.id).toList()},
          timeout: const Duration(seconds: 20),
        );
        final reelId = reelRes?['reelId'] as String?;
        if (reelId == null) {
          throw Exception('Impossible de préparer les vidéos liées au tirage.');
        }
        qrUrl = '${AppConfig.backendUrl}/api/video/poster-video-reel?o=$reelId';
      }

      if (!mounted) return;
      setState(() => _orderMessage = 'Génération du tirage…');

      // 2. PDF plein cadre
      final pdfBytes = await PosterPdfService.generate(
        photoBytes: _photoBytes,
        layout: _layout,
        size: _size,
        orientation: _orientation,
        caption: _captionCtrl.text,
        qrUrl: qrUrl,
      );

      if (!mounted) return;
      setState(() => _orderMessage = 'Envoi du PDF…');

      // 3. Upload R2 (URL stable, comme les livres)
      final uploaded = await PdfService.uploadPosterPdf(pdfBytes);
      if (uploaded == null) {
        throw Exception('Envoi du PDF impossible — réessaie dans un instant.');
      }

      if (!mounted) return;

      if (isEdit) {
        setState(() => _orderMessage = 'Renvoi à l\'impression…');
        await OrderService.sendToPrint(widget.editOrderId!, pdfUrl: uploaded.url);
        if (!mounted) return;
        context.go('/orders/${widget.editOrderId}');
        return;
      }

      setState(() => _orderMessage = 'Création de la commande…');

      final price = PosterPricing.price(_size, _orientation) ?? 0;
      final entry = PosterPricing.entryFor(_size, _orientation);
      final order = OrderModel(
        id: '',
        userId: user.uid,
        userEmail: user.email ?? '',
        bookTitle: 'Tirage $_size',
        coverType: '',
        price: price,
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        street: _streetCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
        npa: _npaCtrl.text.trim(),
        country: _countryCtrl.text.trim(),
        status: 'received',
        createdAt: DateTime.now(),
        notebookId: '',
        memoryCount: _uniqueMemories.length,
        pdfUrl: uploaded.url,
        productType: 'poster',
        posterSku: entry?.sku,
        posterSize: _size,
        posterOrientation: _orientation,
        posterHangerColor: _color,
        posterCaption: _captionCtrl.text.trim().isNotEmpty ? _captionCtrl.text.trim() : null,
        posterMemoryIds: _uniqueMemories.map((m) => m.id).toList(),
        posterPhotoUrl: _photoUrls.isNotEmpty
            ? _photoUrls[_featured.isNotEmpty ? _featured.first : 0]
            : null,
      );
      final orderId = await OrderService.createOrder(order);

      if (!mounted) return;
      context.go('/order-confirmation/$orderId');
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
      if (mounted) {
        setState(() {
          _ordering = false;
          _orderMessage = '';
        });
      }
    }
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('Créer le tirage',
            style: TextStyle(
                fontFamily: 'Fraunces',
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_loadError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textMedium)),
                  ),
                )
              : switch (_step) {
                  0 => _buildCollageStep(),
                  1 => _buildSizeStep(),
                  _ => _buildOrderStep(),
                },
    );
  }

  // ── Étape 0 : collage + légende ───────────────────────────────────────────

  /// Texte d'aide de la mise en avant — dépend du nombre de photos, parce que
  /// la règle n'est pas la même (1 seule vedette jusqu'à 4 photos, autant
  /// qu'on veut au-delà).
  String get _featuredHint {
    final n = _photoUrls.length;
    if (n <= 1) return 'Une seule photo : elle occupe tout le tirage.';
    if (n <= 4) {
      return _featured.isEmpty
          ? 'Tape une photo pour l\'agrandir — à ce nombre de photos, une seule à la fois.'
          : 'Tape une autre photo pour l\'agrandir à sa place, ou la même pour revenir à égalité.';
    }
    final count = _featured.length;
    return count == 0
        ? 'Tape les photos à mettre en avant : chacune prend 4 fois la place d\'une autre.'
        : '$count photo${count > 1 ? 's' : ''} en avant — tape une photo pour l\'agrandir, retape-la pour la remettre à égalité.';
  }

  /// Explique la règle « le format suit le collage » avec les chiffres du
  /// collage courant (voir poster_format_rules.dart).
  String get _formatRuleText {
    final n = _photoUrls.length;
    final cm = PosterFormatRules.smallestTileCm(_layout, _minSize);
    final each = cm == null
        ? ''
        : ' — la plus petite photo y fait ${cm.toStringAsFixed(0)} cm de côté';
    if (n == 1) {
      return 'Une photo plein cadre : tous les formats sont ouverts, du $_minSize au A0.';
    }
    return '$n photos : format $_minSize minimum$each. En dessous, chaque photo deviendrait une vignette — les formats plus petits sont verrouillés.';
  }

  /// Largeur/hauteur de la page choisie (identique pour tous les formats A,
  /// seule l'orientation change) — sert à l'aperçu du collage.
  double get _pageAspectRatio {
    final mm = PosterPricing.mmFor(_size, _orientation) ??
        PosterPricing.mmFor('A4', 'portrait')!;
    return mm.wMm / mm.hMm;
  }

  Widget _buildCollageStep() {
    final multi = _photoUrls.length > 1;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        if (multi) ...[
          Row(
            children: [
              const Expanded(
                child: Text('Photos en avant',
                    style: TextStyle(
                        fontFamily: 'PlayfairDisplay',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark)),
              ),
              if (_featured.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    _featured.clear();
                    _syncSizeToLayout();
                  }),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Toutes à égalité',
                      style: TextStyle(
                          color: AppColors.sageDark,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(_featuredHint,
              style: const TextStyle(
                  fontSize: 12.5, color: AppColors.textMedium, height: 1.35)),
          const SizedBox(height: 10),
        ],
        AspectRatio(
          // Proportions RÉELLES du papier (ISO 216 : 1/√2), pas un 3/4
          // approximatif : maintenant que le format est imposé par le
          // collage, l'aperçu doit montrer la vraie forme du tirage.
          aspectRatio: _pageAspectRatio,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 6)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;
                  // Même découpage que PosterPdfService.generate : les cases
                  // se partagent (1 - posterBandFraction) de la hauteur, le
                  // reste est la bande titre/QR — l'aperçu doit être fidèle
                  // au vrai fichier envoyé à l'impression.
                  final contentH = h * (1 - posterBandFraction);
                  final bandH = h * posterBandFraction;
                  return Stack(
                    children: [
                      for (var i = 0;
                          i < _layout.tiles.length && i < _photoUrls.length;
                          i++)
                        Positioned(
                          left: _layout.tiles[i].x * w,
                          top: _layout.tiles[i].y * contentH,
                          width: _layout.tiles[i].w * w,
                          height: _layout.tiles[i].h * contentH,
                          child: _CollageTile(
                            url: _photoUrls[i],
                            featured: _featured.contains(i),
                            bottleneck: _bottleneckIndex == i,
                            selectable: _photoUrls.length > 1,
                            onTap: () => _toggleFeatured(i),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        top: contentH,
                        width: w,
                        height: bandH,
                        child: _BandPreview(captionCtrl: _captionCtrl, hasMedia: _hasMedia),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.sageTint,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.straighten, size: 18, color: AppColors.sageDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_formatRuleText,
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.textDark, height: 1.35)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text('Texte sur le tirage (optionnel)',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
        const SizedBox(height: 8),
        TextField(
          controller: _captionCtrl,
          maxLength: 40,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Ex. « Léa, 2 ans »',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        Text(
          _hasMedia
              ? 'Affiché dans la bande du bas, à côté du QR code (vidéos/mémos vocaux des souvenirs choisis).'
              : 'Affiché dans la bande du bas. Pas de vidéo ni de mémo vocal dans ces souvenirs : pas de QR code imprimé.',
          style: const TextStyle(fontSize: 11.5, color: AppColors.textMedium),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: () => setState(() => _step = 1),
          style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Choisir la taille'),
        ),
      ],
    );
  }

  // ── Étape 1 : taille / couleur ────────────────────────────────────────────

  Widget _buildSizeStep() {
    final quality = _quality;
    final allowed = _allowedSizes;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        const Text('Taille',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
        const SizedBox(height: 6),
        Text(_formatRuleText,
            style: const TextStyle(
                fontSize: 12.5, color: AppColors.textMedium, height: 1.35)),
        const SizedBox(height: 10),
        for (final size in PosterPricing.sizes)
          _SizeCard(
            size: size,
            quality: quality[size],
            // Trop PETIT pour ce collage (PosterFormatRules) — l'inverse du
            // verdict qualité, qui interdit les formats trop GRANDS pour la
            // résolution des photos. Un format absent du catalogue dans cette
            // orientation (A0 paysage) n'est pas "trop petit" : on le laisse
            // au verdict qualité, qui dit "indisponible".
            tooSmall: !allowed.contains(size) &&
                PosterPricing.entryFor(size, _orientation) != null,
            photoCount: _photoUrls.length,
            tileCm: PosterFormatRules.smallestTileCm(_layout, size),
            price: PosterPricing.price(size, _orientation),
            selected: _size == size,
            onTap: () {
              if (!allowed.contains(size) &&
                  PosterPricing.entryFor(size, _orientation) != null) {
                _showSnack(
                    '$size est trop petit pour ${_photoUrls.length} photos — format minimum : $_minSize.');
                return;
              }
              final q = quality[size];
              if (q == null || q.verdict == PosterQualityVerdict.disabled) {
                if (q?.bottleneckPhotoIndex != null) {
                  setState(() {
                    _bottleneckIndex = q!.bottleneckPhotoIndex;
                    _step = 0;
                  });
                  _showSnack(
                      'Taille $size trop juste : la photo entourée en rouge n\'est pas assez nette pour cette taille — retire-la ou enlève sa mise en avant.');
                } else {
                  _showSnack('Taille $size indisponible pour cette orientation.');
                }
                return;
              }
              setState(() {
                _size = size;
                _bottleneckIndex = null;
              });
            },
          ),
        const SizedBox(height: 20),
        const Text('Couleur du support',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final color in PosterPricing.hangerColors)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _ColorChip(
                    color: color,
                    selected: _color == color,
                    onTap: () => setState(() => _color = color),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: () {
            final err = _sizeValidationError();
            if (err != null) {
              _showSnack(err);
              return;
            }
            setState(() => _step = 2);
          },
          style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Continuer'),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _step = 0),
            child: const Text('← Retour au collage',
                style: TextStyle(color: AppColors.textMedium, fontSize: 13)),
          ),
        ),
      ],
    );
  }

  // ── Étape 2 : adresse + commande ──────────────────────────────────────────

  Widget _buildOrderStep() {
    final price = PosterPricing.price(_size, _orientation);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.sageTint,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.image_outlined, color: AppColors.sageDark),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Tirage $_size · ${_orientation == 'landscape' ? 'Paysage' : 'Portrait'} · ${PosterPricing.hangerColorLabel(_color)}',
                  style: const TextStyle(fontSize: 13.5, color: AppColors.textDark),
                ),
              ),
              Text(price != null ? PosterPricing.format(price) : '—',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textDark)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Form(
          key: _addressKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Adresse de livraison',
                  style: TextStyle(
                      fontFamily: 'PlayfairDisplay',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _AddressField(_firstNameCtrl, 'Prénom', required: true)),
                const SizedBox(width: 10),
                Expanded(child: _AddressField(_lastNameCtrl, 'Nom', required: true)),
              ]),
              const SizedBox(height: 10),
              _AddressField(_streetCtrl, 'Rue et numéro', required: true),
              const SizedBox(height: 10),
              Row(children: [
                SizedBox(
                    width: 100,
                    child: _AddressField(_npaCtrl, 'NPA',
                        required: true, keyboardType: TextInputType.number)),
                const SizedBox(width: 10),
                Expanded(child: _AddressField(_cityCtrl, 'Ville', required: true)),
              ]),
              const SizedBox(height: 10),
              _AddressField(_countryCtrl, 'Pays', required: true),
              const SizedBox(height: 20),
              if (_ordering) ...[
                const LinearProgressIndicator(
                  backgroundColor: Color(0xFFEEEBE3),
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.sage),
                ),
                const SizedBox(height: 10),
                Text(_orderMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppColors.textMedium, fontSize: 13, fontStyle: FontStyle.italic)),
              ] else
                ElevatedButton(
                  onPressed: _placeOrder,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.amber, foregroundColor: Colors.white),
                  child: Text(widget.editOrderId != null ? 'Renvoyer' : 'Commander'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _step = 1),
            child: const Text('← Changer la taille',
                style: TextStyle(color: AppColors.textMedium, fontSize: 13)),
          ),
        ),
      ],
    );
  }
}

/// Aperçu de la bande du bas, fidèle à ce que dessine PosterPdfService.generate
/// (texte à gauche, QR à droite si `hasMedia`) — jusqu'ici invisible avant
/// commande, seulement décrit par un texte d'aide. Se met à jour en direct
/// avec la saisie du texte (écoute `captionCtrl`).
class _BandPreview extends StatelessWidget {
  final TextEditingController captionCtrl;
  final bool hasMedia;
  const _BandPreview({required this.captionCtrl, required this.hasMedia});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: AnimatedBuilder(
              animation: captionCtrl,
              builder: (_, __) {
                final text = captionCtrl.text.trim();
                return Text(
                  text.isEmpty ? '' : text,
                  maxLines: 2,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: AppColors.textDark,
                  ),
                );
              },
            ),
          ),
          if (hasMedia) ...[
            const SizedBox(width: 6),
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.textDark, width: 1),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const Icon(Icons.qr_code_2, size: 14, color: AppColors.textDark),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CollageTile extends StatelessWidget {
  final String url;
  final bool featured;
  final bool bottleneck;
  final bool selectable;
  final VoidCallback onTap;
  const _CollageTile({
    required this.url,
    required this.featured,
    this.bottleneck = false,
    required this.selectable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: selectable ? onTap : null,
      child: Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          border: bottleneck
              ? Border.all(color: AppColors.error, width: 3)
              : featured
                  ? Border.all(color: Colors.white, width: 3)
                  : null,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: AppColors.sageTint),
              errorWidget: (_, __, ___) => Container(color: AppColors.sageTint),
            ),
            // Étoile pleine sur les vedettes, étoile creuse (discrète) sur
            // les autres : sans elle, rien ne dit que les cases se tapent.
            if (featured || selectable)
              Positioned(
                right: 4,
                top: 4,
                child: Icon(
                  featured ? Icons.star : Icons.star_border,
                  color: featured ? Colors.white : Colors.white70,
                  size: featured ? 18 : 15,
                  shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
                ),
              ),
            // Photo désignée par PosterQualityService comme responsable du
            // blocage qualité de la taille tapée par l'utilisateur — voir
            // _bottleneckIndex dans _PosterGenerateScreenState.
            if (bottleneck)
              const Positioned(
                left: 4,
                bottom: 4,
                child: Icon(Icons.warning_amber_rounded,
                    color: AppColors.error,
                    size: 18,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
              ),
          ],
        ),
      ),
    );
  }
}

class _SizeCard extends StatelessWidget {
  final String size;
  final PosterSizeQuality? quality;
  /// Format verrouillé parce qu'il est trop petit pour le nombre de photos
  /// (PosterFormatRules), indépendamment de la qualité des photos.
  final bool tooSmall;
  final int photoCount;
  /// Côté de la plus petite photo du collage à ce format, en cm.
  final double? tileCm;
  final double? price;
  final bool selected;
  final VoidCallback onTap;
  const _SizeCard({
    required this.size,
    required this.quality,
    required this.tooSmall,
    required this.photoCount,
    required this.tileCm,
    required this.price,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled =
        tooSmall || quality == null || quality!.verdict == PosterQualityVerdict.disabled;
    final badge = tooSmall
        ? ('📐', AppColors.textMedium, 'Trop petit pour $photoCount photos')
        : switch (quality?.verdict) {
            PosterQualityVerdict.ok => ('✅', AppColors.sage, 'Qualité parfaite'),
            PosterQualityVerdict.limited => ('⚠️', AppColors.amber, 'Qualité limite'),
            _ => ('🚫', AppColors.error, 'Indisponible'),
          };
    final tileLabel = photoCount > 1 && tileCm != null
        ? ' · ${tileCm!.toStringAsFixed(0)} cm par photo'
        : '';
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? AppColors.sageDark : AppColors.border,
              width: selected ? 1.2 : 0.5,
            ),
          ),
          child: Row(
            children: [
              Text(badge.$1, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(size,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textDark)),
                    Text('${badge.$3}$tileLabel',
                        style: TextStyle(fontSize: 11.5, color: badge.$2)),
                  ],
                ),
              ),
              if (price != null)
                Text(PosterPricing.format(price!),
                    style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textDark)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorChip extends StatelessWidget {
  final String color;
  final bool selected;
  final VoidCallback onTap;
  const _ColorChip({required this.color, required this.selected, required this.onTap});

  Color get _swatch => switch (color) {
        'black' => const Color(0xFF2B2B2B),
        'white' => const Color(0xFFF7F5F0),
        _ => const Color(0xFFB98A4E),
      };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.sageDark : AppColors.border,
            width: selected ? 1.5 : 0.5,
          ),
        ),
        child: Column(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: _swatch,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
            ),
            const SizedBox(height: 6),
            Text(PosterPricing.hangerColorLabel(color),
                style: const TextStyle(fontSize: 11.5, color: AppColors.textDark)),
          ],
        ),
      ),
    );
  }
}

class _AddressField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool required;
  final TextInputType keyboardType;
  const _AddressField(this.controller, this.label,
      {this.required = false, this.keyboardType = TextInputType.text});

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 14, color: AppColors.textDark),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 13, color: AppColors.textMedium),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          isDense: true,
        ),
        validator: required
            ? (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null
            : null,
      );
}
