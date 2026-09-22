import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/pdf_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/poster_pdf_service.dart' show PosterPdfService;
import '../../core/services/puzzle_pricing.dart';
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
  final String? photoKey;
  final String? photoUrl;

  const _QueuedPuzzle({
    required this.sku,
    required this.size,
    required this.price,
    required this.pdfUrl,
    this.photoKey,
    this.photoUrl,
  });

  Map<String, dynamic> toMap() => {
        'puzzleSku': sku,
        'puzzleSize': size,
        'price': price,
        'pdfUrl': pdfUrl,
        'puzzlePhotoKey': photoKey,
        'puzzlePhotoUrl': photoUrl,
      };
}

class _PuzzleGenerateScreenState extends State<PuzzleGenerateScreen> {
  int _step = 0; // 0 = taille, 1 = adresse/commande

  bool _loading = true;
  String? _loadError;
  String? _photoUrl;
  String? _photoKey; // clé R2, si la photo en a une (sinon URL Firebase héritée)
  Uint8List? _photoBytes;

  String _size = '500';

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

      setState(() {
        _photoUrl = url;
        _photoKey = key;
        _photoBytes = bytesList.first;
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

      final entry = PuzzlePricing.entryFor(_size);

      if (widget.queueMode) {
        Navigator.pop(
          context,
          _QueuedPuzzle(
            sku: entry?.sku,
            size: _size,
            price: PuzzlePricing.price(_size) ?? 0,
            pdfUrl: uploaded.url,
            photoKey: _photoKey,
            photoUrl: _photoKey == null ? _photoUrl : null,
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
        puzzlePhotoUrl: _photoKey == null ? _photoUrl : null,
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
        if (_photoUrl != null)
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
          'Plus il y a de pièces, plus le puzzle est grand et difficile — Prodigi recadre la photo pour remplir le puzzle et le couvercle de la boîte métal.',
          style: TextStyle(fontSize: 12.5, color: AppColors.textMedium, height: 1.35),
        ),
        const SizedBox(height: 10),
        for (final size in PuzzlePricing.sizes)
          _PuzzleSizeCard(
            size: size,
            selected: _size == size,
            onTap: () => setState(() => _size = size),
          ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: () => setState(() => _step = 1),
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
                  backgroundColor: AppColors.amber, foregroundColor: Colors.white),
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
                        backgroundColor: AppColors.amber, foregroundColor: Colors.white),
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
  final VoidCallback onTap;
  const _PuzzleSizeCard({
    required this.size,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final price = PuzzlePricing.price(size);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.sageTint : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.sageDark : AppColors.border,
              width: selected ? 1.5 : 0.5,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: selected ? AppColors.sageDark : AppColors.softGray,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(PuzzlePricing.label(size),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark)),
              ),
              Text(price != null ? PuzzlePricing.format(price) : '—',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textDark)),
            ],
          ),
        ),
      ),
    );
  }
}
