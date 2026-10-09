import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/pdf_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/poster_pdf_service.dart' show PosterPdfService;
import '../../core/services/backend_client.dart';
import '../../core/services/puzzle_lid_pdf_service.dart';
import '../../core/services/puzzle_pricing.dart';
import '../../core/services/puzzle_quality_service.dart';
import '../../core/utils/image_dims.dart';
import '../books/book_generate_widgets.dart' show AddressField;

/// Génération d'un puzzle photo à partir de LA photo choisie à l'écran
/// précédent (puzzle_select_screen.dart). Équivalent poster, en plus court
/// encore : une seule photo, pas de collage ni d'orientation à choisir —
/// juste la taille (nombre de pièces) puis l'adresse. Prodigi cadre
/// lui-même la photo dans le puzzle et le couvercle de la boîte
/// (`sizing: 'fillPrintArea'`), donc aucun traitement d'image côté app.
class PuzzleGenerateScreen extends StatefulWidget {
  final String memoryId;
  final int photoIndex;

  /// Photo choisie DIRECTEMENT dans la galerie du téléphone (PuzzleSelectScreen
  /// → « Une photo de mon téléphone »), en pleine résolution. Quand elle est
  /// fournie, il n'y a pas de souvenir derrière le puzzle : `memoryId` est
  /// vide, le couvercle n'a pas de QR (aucune vidéo à pointer) et ces octets
  /// sont à la fois l'aperçu et le fichier d'impression.
  ///
  /// C'est le chemin à privilégier pour un grand puzzle : les photos
  /// enregistrées dans un souvenir sont compressées à 2048 px (assez pour un
  /// livre, pas pour un puzzle), alors que l'originale du téléphone fait
  /// couramment 4000 px et plus.
  final Uint8List? galleryBytes;
  /// true pour un puzzle ajouté via "+ Ajouter un autre puzzle à cette
  /// commande" depuis une commande déjà en cours (voir _buildOrderStep du
  /// parent) : même étape taille, mais l'étape finale envoie juste la photo
  /// et renvoie le résultat au parent (`Navigator.pop`) au lieu de demander
  /// une adresse et créer une commande.
  final bool queueMode;
  const PuzzleGenerateScreen({
    super.key,
    required this.memoryId,
    required this.photoIndex,
    this.queueMode = false,
    this.galleryBytes,
  });

  @override
  State<PuzzleGenerateScreen> createState() => _PuzzleGenerateScreenState();
}

/// Un puzzle configuré et envoyé via `queueMode`, en attente d'être inclus
/// dans la commande du parent — voir _PuzzleGenerateScreenState._addAnotherPuzzle.
class _QueuedPuzzle {
  final String? sku;
  final String size;
  final double price;
  final String pdfUrl; // en fait une URL de photo (JPG), nom gardé générique
  /// PDF du couvercle composé (photo + titre + QR) — null si le souvenir n'a
  /// ni vidéo ni mémo vocal.
  final String? lidUrl;
  final String? photoKey;
  final String? photoUrl;

  const _QueuedPuzzle({
    required this.sku,
    required this.size,
    required this.price,
    required this.pdfUrl,
    this.lidUrl,
    this.photoKey,
    this.photoUrl,
  });

  Map<String, dynamic> toMap() => {
        'puzzleSku': sku,
        'puzzleSize': size,
        'price': price,
        'pdfUrl': pdfUrl,
        'puzzleLidUrl': lidUrl,
        'puzzlePhotoKey': photoKey,
        'puzzlePhotoUrl': photoUrl,
      };
}

class _PuzzleGenerateScreenState extends State<PuzzleGenerateScreen> {
  int _step = 0; // 0 = taille, 1 = adresse/commande

  bool _loading = true;
  String? _loadError;
  /// Souvenir d'origine de la photo — gardé pour composer le couvercle :
  /// son titre et ses vidéos/mémos vocaux deviennent le bandeau et la cible
  /// du QR (voir PuzzleLidPdfService).
  MemoryModel? _memory;
  String? _photoUrl;
  String? _photoKey; // clé R2, si la photo en a une (sinon URL Firebase héritée)
  Uint8List? _photoBytes;

  /// Dimensions réelles de la photo, lues dans l'en-tête JPEG/PNG — base du
  /// contrôle qualité par taille (PuzzleQualityService). null si l'en-tête
  /// n'a pas pu être lu : le service traite ce cas en « qualité limite »
  /// plutôt qu'en blocage.
  ({int w, int h})? _photoDims;

  /// true dès que l'utilisateur a remplacé la photo du souvenir par
  /// l'ORIGINALE prise dans sa galerie (voir [_useOriginalPhoto]).
  ///
  /// Pourquoi ce chemin existe : `PhotoService` stocke les photos compressées
  /// à 2048 px, ce qui suffit pour un livre mais plafonne un puzzle 252
  /// pièces à ~139 DPI — sous le seuil de 150. Autrement dit, avec la seule
  /// photo stockée, AUCUNE taille de puzzle n'est commandable. Plutôt que
  /// d'abaisser le seuil pour sauver la vente (ce qui reviendrait à imprimer
  /// du flou en connaissance de cause), on va chercher l'originale sur
  /// l'appareil. Elle n'est utilisée que comme fichier d'impression : la
  /// vignette de la commande reste celle du souvenir.
  bool _usingOriginal = false;

  /// true si le souvenir a au moins une vidéo ou un mémo vocal, donc si le
  /// couvercle recevra un QR (voir [_buildLid]).
  bool get _hasLidMedia =>
      (_memory?.videoKeys.isNotEmpty ?? false) || _memory?.audioKey != null;

  bool get _isAdmin =>
      FirebaseAuth.instance.currentUser?.email == AppConfig.adminEmail;
  bool _checkingProdigi = false;
  String? _prodigiResult;

  Map<String, PuzzleSizeQuality> get _quality =>
      PuzzleQualityService.evaluateAll(_photoDims);

  /// Pas de taille en dur : on part sur la plus grande que la photo supporte
  /// vraiment (avant le 06.10.26, '500' était imposé — soit ~98 DPI avec une
  /// photo stockée à 2048 px). `_size` reste vide tant que la photo n'est pas
  /// chargée ; l'étape taille ne s'affiche qu'après.
  String _size = '';

  final _addressKey = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _streetCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _npaCtrl = TextEditingController();
  final _countryCtrl = TextEditingController(text: 'Suisse');
  bool _ordering = false;
  String _orderMessage = '';

  // Puzzles supplémentaires déjà configurés et envoyés (photo uploadée), en
  // attente d'être inclus dans la même commande que celui de cet écran —
  // voir OrderModel.additionalPuzzles / _addAnotherPuzzle. Toujours vide en
  // queueMode.
  final List<_QueuedPuzzle> _extraPuzzles = [];
  double get _totalPrice =>
      (PuzzlePricing.price(_size) ?? 0) +
      _extraPuzzles.fold(0.0, (sum, p) => sum + p.price);

  /// Explication affichée sous les cartes quand au moins une taille est
  /// bloquée par la résolution. Dire POURQUOI évite le « bug » apparent
  /// d'une carte grisée sans raison.
  String? get _blockedExplanation {
    final blocked = PuzzlePricing.sizes
        .where((s) =>
            _quality[s]?.verdict == PuzzleQualityVerdict.disabled)
        .toList();
    if (blocked.isEmpty) return null;
    final labels = blocked.map(PuzzlePricing.label).join(', ');
    if (blocked.length == PuzzlePricing.sizes.length) {
      return 'Cette photo est trop petite pour un puzzle, quelle que soit la '
          'taille ($labels). Choisis une photo plus grande — les captures '
          'd\'écran et les images reçues par messagerie sont souvent trop '
          'compressées.';
    }
    return 'Trop peu de pixels dans cette photo pour $labels : le puzzle '
        'sortirait visiblement flou. Les tailles proposées ci-dessus sont '
        'celles que cette photo peut remplir correctement.';
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _streetCtrl.dispose();
    _cityCtrl.dispose();
    _npaCtrl.dispose();
    _countryCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    // Photo venue de la galerie : rien à aller chercher, ces octets SONT la
    // photo d'impression (et l'aperçu). Aucun souvenir, donc pas de QR sur le
    // couvercle — on n'imprime jamais un code qui ne mène nulle part.
    final gallery = widget.galleryBytes;
    if (gallery != null) {
      final dims = imageDims(gallery);
      setState(() {
        _photoBytes = gallery;
        _photoDims = dims;
        _usingOriginal = true;
        _size = PuzzleQualityService.largestOrderable(dims) ??
            PuzzlePricing.sizes.first;
        _loading = false;
      });
      return;
    }
    try {
      final visible = await MemoryQueryService.visible()
          .first
          .timeout(const Duration(seconds: 20));
      MemoryModel? memory;
      for (final m in visible) {
        if (m.id == widget.memoryId) {
          memory = m;
          break;
        }
      }
      if (memory == null) {
        setState(() {
          _loadError = 'Souvenir introuvable.';
          _loading = false;
        });
        return;
      }

      String? url;
      String? key;
      if (memory.mediaKeys.isNotEmpty) {
        final keyToUrl = await PhotoService.signedUrlsForMemory(memory.id);
        final entries = keyToUrl.entries.toList();
        if (widget.photoIndex >= 0 && widget.photoIndex < entries.length) {
          key = entries[widget.photoIndex].key;
          url = entries[widget.photoIndex].value;
        }
      } else if (memory.mediaUrls.isNotEmpty) {
        if (widget.photoIndex >= 0 && widget.photoIndex < memory.mediaUrls.length) {
          url = memory.mediaUrls[widget.photoIndex];
        }
      } else if (memory.photoUrl != null && memory.photoUrl!.isNotEmpty) {
        url = memory.photoUrl;
      }
      if (url == null) {
        setState(() {
          _loadError = 'Photo introuvable dans ce souvenir.';
          _loading = false;
        });
        return;
      }

      final bytesList = await PosterPdfService.downloadPhotoBytes([url]);
      if (bytesList.isEmpty) {
        setState(() {
          _loadError = 'Impossible de charger la photo — réessaie.';
          _loading = false;
        });
        return;
      }

      final bytes = bytesList.first;
      final dims = imageDims(bytes);
      setState(() {
        _memory = memory;
        _photoUrl = url;
        _photoKey = key;
        _photoBytes = bytes;
        _photoDims = dims;
        // La plus grande taille que cette photo supporte réellement. Si même
        // la plus petite est bloquée (photo minuscule), on retombe sur la
        // plus petite : l'étape taille affichera alors toutes les cartes
        // désactivées avec leur DPI, ce qui explique le blocage au lieu de
        // présenter un écran vide.
        _size = PuzzleQualityService.largestOrderable(dims) ??
            PuzzlePricing.sizes.first;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadError = 'Erreur de chargement — réessaie.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _placeOrder() async {
    // Garde de ré-entrance : même raisonnement que book/poster _placeOrder.
    if (_ordering) return;
    // Pas d'adresse en queueMode : ce puzzle rejoint une commande dont
    // l'adresse est saisie sur l'écran racine (voir _buildOrderStep).
    if (!widget.queueMode && !(_addressKey.currentState?.validate() ?? false)) {
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _photoBytes == null) return;

    setState(() {
      _ordering = true;
      _orderMessage = 'Envoi de la photo…';
    });
    try {
      final uploaded = await PdfService.uploadPuzzlePhoto(_photoBytes!);
      if (uploaded == null) {
        throw Exception('Envoi de la photo impossible — réessaie dans un instant.');
      }

      if (!mounted) return;

      // Couvercle de la boîte : photo + titre du souvenir + QR vers ses
      // vidéos et mémos vocaux. Le « reel » (cible du QR) est créé AVANT le
      // PDF, puisque son URL doit déjà être imprimée dedans — même ordre que
      // le poster. Sans média dans le souvenir, pas de QR et pas de couvercle
      // composé : le backend retombe sur la photo brute, et on n'imprime
      // jamais un code qui ne mène nulle part.
      final lidUrl = await _buildLid(uploadedPhotoFallback: uploaded.url);

      if (!mounted) return;

      final entry = PuzzlePricing.entryFor(_size);

      if (widget.queueMode) {
        Navigator.pop(
          context,
          _QueuedPuzzle(
            sku: entry?.sku,
            size: _size,
            lidUrl: lidUrl,
            // Prix d'un article SUPPLÉMENTAIRE : port déduit. Prodigi ne
            // facture la livraison qu'une fois par commande groupée — la
            // compter sur chaque article surfacturait le client (audit du
            // 01.10.26). Le backend recalcule à l'identique.
            price: PuzzlePricing.priceAdditional(_size) ?? 0,
            pdfUrl: uploaded.url,
            photoKey: _photoKey,
            // Sans souvenir derrière (photo de la galerie), la photo envoyée
            // sert aussi de vignette : sinon la commande s'afficherait sans
            // image dans « Mes commandes » et dans la console admin.
            photoUrl: _photoKey == null ? (_photoUrl ?? uploaded.url) : null,
          ),
        );
        return;
      }

      setState(() => _orderMessage = 'Création de la commande…');

      final order = OrderModel(
        id: '',
        userId: user.uid,
        userEmail: user.email ?? '',
        bookTitle: 'Puzzle ${PuzzlePricing.label(_size)}',
        coverType: '',
        price: _totalPrice,
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        street: _streetCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
        npa: _npaCtrl.text.trim(),
        country: _countryCtrl.text.trim(),
        status: 'received',
        createdAt: DateTime.now(),
        notebookId: '',
        memoryCount: 1,
        pdfUrl: uploaded.url,
        productType: 'puzzle',
        puzzleSku: entry?.sku,
        puzzleSize: _size,
        puzzlePhotoKey: _photoKey,
        puzzlePhotoUrl: _photoKey == null ? (_photoUrl ?? uploaded.url) : null,
        puzzleLidUrl: lidUrl,
        additionalPuzzles: _extraPuzzles.isEmpty
            ? null
            : _extraPuzzles.map((p) => p.toMap()).toList(),
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

  /// Compose et envoie le PDF du COUVERCLE, et renvoie son URL stable — ou
  /// null s'il n'y a pas de QR à imprimer (souvenir sans vidéo ni mémo vocal)
  /// ou si une étape échoue.
  ///
  /// Un échec ici ne doit JAMAIS faire échouer la commande : le couvercle est
  /// un bonus, et le backend sait retomber sur la photo brute. On préfère un
  /// puzzle sans QR à une commande perdue après paiement.
  Future<String?> _buildLid({required String uploadedPhotoFallback}) async {
    final memory = _memory;
    if (memory == null) return null;
    final hasMedia = memory.videoKeys.isNotEmpty || memory.audioKey != null;
    if (!hasMedia) return null;

    try {
      setState(() => _orderMessage = 'Préparation des vidéos liées…');
      final reelRes = await BackendClient.postJson(
        '/api/video/poster-reel-create',
        {
          'memoryIds': [memory.id],
          'videoKeys': memory.videoKeys,
          'audioMemoryIds': memory.audioKey != null ? [memory.id] : <String>[],
        },
        timeout: const Duration(seconds: 20),
      );
      final reelId = reelRes?['reelId'] as String?;
      if (reelId == null) return null;

      if (!mounted) return null;
      setState(() => _orderMessage = 'Composition du couvercle…');
      final pdf = await PuzzleLidPdfService.generate(
        photoBytes: _photoBytes!,
        size: _size,
        caption: memory.title,
        qrUrl:
            '${AppConfig.backendUrl}/api/video/poster-video-reel?o=$reelId',
      );

      if (!mounted) return null;
      setState(() => _orderMessage = 'Envoi du couvercle…');
      final up = await PdfService.uploadPuzzleLidPdf(pdf);
      return up?.url;
    } catch (_) {
      return null;
    }
  }

  /// Mesure les deux inconnues du catalogue puzzle, en un appel chacun
  /// (admin, gratuit, ne commande rien) :
  ///   1. le PORT RÉEL d'une commande groupée — devis à 1 puis à 2
  ///      exemplaires, la différence donne l'article sans port, donc le port.
  ///      `PuzzlePricing._shippingUsd` vaut 12 USD en dur, jamais confirmé ;
  ///   2. les DIMENSIONS DE LA ZONE `lid` (couvercle), que le catalogue ne
  ///      conserve pas et qu'il faut connaître pour y imprimer un QR sans
  ///      risquer que `fillPrintArea` le recadre hors du couvercle.
  Future<void> _measureProdigi() async {
    setState(() {
      _checkingProdigi = true;
      _prodigiResult = null;
    });
    try {
      final one = await OrderService.verifyPuzzleQuote(size: _size, copies: 1);
      final two = await OrderService.verifyPuzzleQuote(size: _size, copies: 2);
      final info = await OrderService.prodigiProductInfo(
          PuzzlePricing.entryFor(_size)!.sku);

      final ship1 = (one['prodigiShippingUsd'] as num?)?.toDouble();
      final items1 = (one['prodigiItemsUsd'] as num?)?.toDouble();
      final items2 = (two['prodigiItemsUsd'] as num?)?.toDouble();
      final ours = (one['localCostUsd'] as num?)?.toStringAsFixed(2);
      // Article supplémentaire = différence des deux devis d'articles. Le
      // port, lui, doit être IDENTIQUE sur les deux devis : s'il double,
      // c'est que Prodigi facture par article et tout le modèle de commande
      // groupée est faux.
      final perExtra =
          (items1 != null && items2 != null) ? (items2 - items1) : null;

      if (!mounted) return;
      setState(() => _prodigiResult = [
            '${PuzzlePricing.label(_size)} (${PuzzlePricing.entryFor(_size)!.sku})',
            'Prodigi 1 ex. : article \$${items1?.toStringAsFixed(2) ?? '?'} + port \$${ship1?.toStringAsFixed(2) ?? '?'}',
            'notre estimation totale : \$${ours ?? '?'}',
            'port à 2 ex. : \$${(two['prodigiShippingUsd'] as num?)?.toDouble().toStringAsFixed(2) ?? '?'} (doit être identique)',
            'article supplémentaire réel : \$${perExtra?.toStringAsFixed(2) ?? '?'} — _shippingUsd vaut 12.00',
            'zones d\'impression : ${info['printAreas']}',
          ].join('\n'));
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _prodigiResult = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _checkingProdigi = false);
    }
  }

  /// Remplace le fichier d'impression par la photo ORIGINALE choisie dans la
  /// galerie de l'appareil, en pleine résolution (`imageQuality: 100`, aucune
  /// contrainte de dimension). Le backend accepte jusqu'à 80 Mo pour une
  /// photo de puzzle, donc un original de téléphone passe largement.
  Future<void> _useOriginalPhoto() async {
    try {
      final picked = await ImagePicker()
          .pickImage(source: ImageSource.gallery, imageQuality: 100);
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      final dims = imageDims(bytes);
      if (!mounted) return;
      if (dims == null) {
        _showSnack('Impossible de lire les dimensions de cette image.');
        return;
      }
      setState(() {
        _photoBytes = bytes;
        _photoDims = dims;
        _usingOriginal = true;
        // La taille choisie peut être redevenue possible — ou l'originale
        // peut être elle aussi trop petite. On réaligne sur ce qui est
        // réellement commandable, sans jamais garder une taille bloquée.
        if (!(_quality[_size]?.isOrderable ?? false)) {
          _size = PuzzleQualityService.largestOrderable(dims) ??
              PuzzlePricing.sizes.first;
        }
      });
    } catch (_) {
      if (mounted) _showSnack('Choix de la photo impossible — réessaie.');
    }
  }

  /// Ouvre un aller-retour complet (choix de la photo, taille) qui renvoie
  /// un puzzle prêt (photo déjà envoyée) plutôt que de créer une commande —
  /// voir PuzzleSelectScreen/PuzzleGenerateScreen en `queueMode`. Ajouté au
  /// panier local (`_extraPuzzles`), inclus dans la commande unique au
  /// moment de "Commander" (voir _placeOrder).
  Future<void> _addAnotherPuzzle() async {
    final item = await context.push<_QueuedPuzzle>('/puzzle/select?queue=1');
    if (item != null && mounted) setState(() => _extraPuzzles.add(item));
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
        title: const Text(
          'Puzzle photo',
          style: TextStyle(
            fontFamily: 'Fraunces',
            fontWeight: FontWeight.w600,
            color: AppColors.textDark,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () =>
              _step == 1 ? setState(() => _step = 0) : context.pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(_loadError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textMedium)),
                  ),
                )
              : (_step == 0 ? _buildSizeStep() : _buildOrderStep()),
    );
  }

  Widget _buildSizeStep() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        // Toujours la photo qui sera RÉELLEMENT imprimée : dès qu'on prend
        // l'originale de la galerie, c'est elle qu'on montre (avant, l'aperçu
        // restait sur la photo du souvenir et on croyait que le choix n'avait
        // pas été pris en compte).
        if (_usingOriginal && _photoBytes != null)
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.memory(_photoBytes!,
                  width: 180, height: 180, fit: BoxFit.cover),
            ),
          )
        else if (_photoUrl != null)
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CachedNetworkImage(
                imageUrl: _photoUrl!,
                width: 180,
                height: 180,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                    width: 180, height: 180, color: AppColors.sageTint),
              ),
            ),
          ),
        const SizedBox(height: 20),
        const Text('Nombre de pièces',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
        const SizedBox(height: 6),
        const Text(
          'Plus il y a de pièces, plus le puzzle est grand — et plus il faut de '
          'pixels dans la photo. Les tailles que ta photo ne peut pas remplir '
          'nettement sont désactivées.',
          style: TextStyle(fontSize: 12.5, color: AppColors.textMedium, height: 1.35),
        ),
        const SizedBox(height: 10),
        for (final size in PuzzlePricing.sizes)
          _PuzzleSizeCard(
            size: size,
            selected: _size == size,
            quality: _quality[size],
            onTap: () => setState(() => _size = size),
          ),
        if (_blockedExplanation != null) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.amber.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.amber.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_blockedExplanation!,
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.textDark, height: 1.4)),
                // Le vrai remède : l'originale de l'appareil, que l'app n'a
                // jamais stockée en pleine résolution. Proposé AUSSI quand la
                // photo vient déjà de la galerie : celle-ci peut être trop
                // petite elle aussi (capture d'écran, image reçue par
                // messagerie), et sans ce bouton on resterait coincé.
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _useOriginalPhoto,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: Text(
                        _usingOriginal
                            ? 'Choisir une autre photo'
                            : 'Choisir la photo originale',
                        style: const TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _usingOriginal
                      ? "Cette photo n'a pas assez de pixels pour les tailles "
                          "grisées. Une photo prise avec l'appareil du téléphone "
                          "passe presque toujours."
                      : "Carnet garde une version allégée de tes photos pour "
                          "que l'app reste rapide. Pour un grand puzzle, va "
                          "rechercher l'originale dans ta galerie.",
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.textMedium, height: 1.35),
                ),
              ],
            ),
          ),
        ],
        if (_usingOriginal && _photoDims != null) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.check_circle_outline,
                  size: 15, color: AppColors.sageDark),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Photo originale · ${_photoDims!.w} × ${_photoDims!.h} px',
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.sageDark),
                ),
              ),
            ],
          ),
        ],
        // Mesures réelles chez Prodigi (admin) : port groupé + zones
        // d'impression, les deux valeurs que le catalogue estime ou ignore.
        if (_isAdmin) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _checkingProdigi ? null : _measureProdigi,
            icon: _checkingProdigi
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.fact_check_outlined, size: 16),
            label: const Text('Mesurer chez Prodigi (port + couvercle)',
                style: TextStyle(fontSize: 12.5)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.amber,
              side: const BorderSide(color: AppColors.amber),
              minimumSize: const Size(0, 36),
            ),
          ),
          if (_prodigiResult != null) ...[
            const SizedBox(height: 6),
            SelectableText(_prodigiResult!,
                style: const TextStyle(
                    fontSize: 11.5, color: AppColors.textMedium, height: 1.4)),
          ],
        ],
        const SizedBox(height: 24),
        ElevatedButton(
          // Une taille bloquée par la qualité ne doit pas pouvoir avancer :
          // c'est un objet physique, payé, qu'on ne peut pas « réessayer ».
          onPressed: (_quality[_size]?.isOrderable ?? false)
              ? () => setState(() => _step = 1)
              : null,
          style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Continuer'),
        ),
      ],
    );
  }

  Widget _buildOrderStep() {
    final price = PuzzlePricing.price(_size);
    // Le panier (autres puzzles + bouton "en ajouter un") n'a de sens que
    // pour la commande racine — pas en queueMode (un puzzle en file
    // d'attente ne porte pas lui-même d'autres puzzles).
    final showCart = !widget.queueMode;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        _puzzleSummaryTile(
          label: 'Puzzle ${PuzzlePricing.label(_size)}',
          price: price,
        ),
        // Le QR du couvercle est ce qui distingue ce puzzle de n'importe quel
        // puzzle photo du marché : on le dit, plutôt que de le laisser
        // découvrir à la livraison.
        if (_hasLidMedia) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.sageTint,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.sageDark.withOpacity(0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.qr_code_2, size: 20, color: AppColors.sageDark),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Le couvercle de la boîte portera un QR code : en le '
                    'scannant, on verra les vidéos et mémos vocaux de ce '
                    'souvenir.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.textDark, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (showCart) ...[
          for (final item in _extraPuzzles)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _puzzleSummaryTile(
                label: 'Puzzle ${PuzzlePricing.label(item.size)}',
                price: item.price,
                onRemove: () => setState(() => _extraPuzzles.remove(item)),
              ),
            ),
          const SizedBox(height: 10),
          Center(
            child: TextButton.icon(
              onPressed: _ordering ? null : _addAnotherPuzzle,
              icon: const Icon(Icons.add_circle_outline,
                  size: 18, color: AppColors.sageDark),
              label: const Text('Ajouter un autre puzzle à cette commande',
                  style: TextStyle(color: AppColors.sageDark, fontSize: 13)),
            ),
          ),
          if (_extraPuzzles.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total · 1 seule livraison',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark)),
                  Text(PuzzlePricing.format(_totalPrice),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, color: AppColors.textDark)),
                ],
              ),
            ),
          ],
        ],
        const SizedBox(height: 24),
        if (widget.queueMode)
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
                  backgroundColor: AppColors.amber, foregroundColor: AppColors.onAccent),
              child: const Text('Ajouter à la commande'),
            )
        else
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
                  Expanded(child: AddressField(_firstNameCtrl, 'Prénom', required: true)),
                  const SizedBox(width: 10),
                  Expanded(child: AddressField(_lastNameCtrl, 'Nom', required: true)),
                ]),
                const SizedBox(height: 10),
                AddressField(_streetCtrl, 'Rue et numéro', required: true),
                const SizedBox(height: 10),
                Row(children: [
                  SizedBox(
                      width: 100,
                      child: AddressField(_npaCtrl, 'NPA',
                          required: true, keyboardType: TextInputType.number)),
                  const SizedBox(width: 10),
                  Expanded(child: AddressField(_cityCtrl, 'Ville', required: true)),
                ]),
                const SizedBox(height: 10),
                AddressField(_countryCtrl, 'Pays', required: true),
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
                        backgroundColor: AppColors.amber, foregroundColor: AppColors.onAccent),
                    child: const Text('Commander'),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _step = 0),
            child: const Text('← Changer la taille',
                style: TextStyle(color: AppColors.textMedium, fontSize: 13)),
          ),
        ),
      ],
    );
  }

  Widget _puzzleSummaryTile({
    required String label,
    required double? price,
    VoidCallback? onRemove,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.sageTint,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.extension_outlined, color: AppColors.sageDark),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 13.5, color: AppColors.textDark)),
          ),
          Text(price != null ? PuzzlePricing.format(price) : '—',
              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textDark)),
          if (onRemove != null)
            GestureDetector(
              onTap: onRemove,
              child: const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.close, size: 18, color: AppColors.textMedium),
              ),
            ),
        ],
      ),
    );
  }
}

class _PuzzleSizeCard extends StatelessWidget {
  final String size;
  final bool selected;

  /// Verdict qualité pour cette taille avec la photo choisie. null = pas
  /// encore évalué (photo en cours de chargement) : la carte reste active,
  /// comme avant le 06.10.26.
  final PuzzleSizeQuality? quality;
  final VoidCallback onTap;
  const _PuzzleSizeCard({
    required this.size,
    required this.selected,
    required this.quality,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final price = PuzzlePricing.price(size);
    final verdict = quality?.verdict;
    final blocked = verdict == PuzzleQualityVerdict.disabled;
    final limited = verdict == PuzzleQualityVerdict.limited;

    // Le DPI n'est affiché que s'il apporte une information : sur une taille
    // « ok », il n'y a rien à décider.
    final note = blocked
        ? 'Photo trop petite · ${PuzzleQualityService.dpiLabel(quality!)}'
        : limited
            ? 'Qualité juste · ${PuzzleQualityService.dpiLabel(quality!)}'
            : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: blocked ? 0.5 : 1,
        child: GestureDetector(
          onTap: blocked ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected && !blocked ? AppColors.sageTint : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected && !blocked ? AppColors.sageDark : AppColors.border,
                width: selected && !blocked ? 1.5 : 0.5,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  blocked
                      ? Icons.block
                      : selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                  color: blocked
                      ? AppColors.softGray
                      : selected
                          ? AppColors.sageDark
                          : AppColors.softGray,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(PuzzlePricing.label(size),
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textDark)),
                      if (note != null) ...[
                        const SizedBox(height: 2),
                        Text(note,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: blocked
                                    ? AppColors.errorText
                                    : AppColors.textMedium)),
                      ],
                    ],
                  ),
                ),
                Text(price != null ? PuzzlePricing.format(price) : '—',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: AppColors.textDark)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
