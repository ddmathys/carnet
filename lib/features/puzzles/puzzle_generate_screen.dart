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
  const PuzzleGenerateScreen({
    super.key,
    required this.memoryId,
    required this.photoIndex,
  });

  @override
  State<PuzzleGenerateScreen> createState() => _PuzzleGenerateScreenState();
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
    if (!(_addressKey.currentState?.validate() ?? false)) return;
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
      setState(() => _orderMessage = 'Création de la commande…');

      final price = PuzzlePricing.price(_size) ?? 0;
      final entry = PuzzlePricing.entryFor(_size);
      final order = OrderModel(
        id: '',
        userId: user.uid,
        userEmail: user.email ?? '',
        bookTitle: 'Puzzle ${PuzzlePricing.label(_size)}',
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
        memoryCount: 1,
        pdfUrl: uploaded.url,
        productType: 'puzzle',
        puzzleSku: entry?.sku,
        puzzleSize: _size,
        puzzlePhotoKey: _photoKey,
        puzzlePhotoUrl: _photoKey == null ? _photoUrl : null,
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
              const Icon(Icons.extension_outlined, color: AppColors.sageDark),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Puzzle ${PuzzlePricing.label(_size)}',
                  style: const TextStyle(fontSize: 13.5, color: AppColors.textDark),
                ),
              ),
              Text(price != null ? PuzzlePricing.format(price) : '—',
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
