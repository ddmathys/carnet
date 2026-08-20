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
import '../../core/services/poster_pdf_service.dart';
import '../../core/services/poster_pricing.dart';
import '../../core/services/poster_quality_service.dart';
import '../../core/utils/image_dims.dart';

/// Génération d'un poster ("Art print with hanger") à partir des photos
/// choisies à l'écran précédent (poster_select_screen.dart). Équivalent
/// poster de BookGenerateScreen, en beaucoup plus court : une seule page, un
/// petit catalogue de tailles fixes (voir poster_pricing.dart).
class PosterGenerateScreen extends StatefulWidget {
  final List<String> memoryIds;
  final String? editOrderId;
  const PosterGenerateScreen({
    super.key,
    this.memoryIds = const [],
    this.editOrderId,
  });

  @override
  State<PosterGenerateScreen> createState() => _PosterGenerateScreenState();
}

class _PosterGenerateScreenState extends State<PosterGenerateScreen> {
  int _step = 0; // 0 = collage, 1 = taille/couleur, 2 = adresse/commande

  List<MemoryModel> _memories = [];
  List<String> _photoUrls = [];
  List<Uint8List> _photoBytes = [];
  List<({int w, int h})?> _photoDims = [];
  final Set<int> _featured = {};

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

  PosterLayout get _layout => buildPosterLayout(_memories.length, _featured);

  Map<String, PosterSizeQuality> get _quality =>
      PosterQualityService.evaluateAll(layout: _layout, photoDims: _photoDims);

  Future<void> _loadData() async {
    setState(() => _loadError = null);
    try {
      final visible = await MemoryQueryService.visible()
          .first
          .timeout(const Duration(seconds: 20));
      final byId = {for (final m in visible) m.id: m};
      final ordered = [
        for (final id in widget.memoryIds)
          if (byId.containsKey(id)) byId[id]!,
      ];
      if (ordered.isEmpty) {
        setState(() {
          _loadError = 'Aucune photo sélectionnée pour ce poster.';
          _loading = false;
        });
        return;
      }
      if (ordered.length > posterMaxPhotos) {
        ordered.removeRange(posterMaxPhotos, ordered.length);
      }

      final urls = <String>[];
      for (final m in ordered) {
        final resolved = await PhotoService.resolvePhotoUrls(m);
        if (resolved.isEmpty) continue;
        urls.add(resolved.first);
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
        _memories = ordered;
        _photoUrls = urls;
        _photoBytes = bytes;
        _photoDims = dims;
        if (urls.length > 1) _featured.add(0);
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
      if (_memories.length <= 4) {
        // 1-4 photos : la vedette change le template (voir poster_template.dart)
        // — un seul choix à la fois pour rester dans le petit catalogue de
        // templates prévu.
        if (!_featured.remove(i)) {
          _featured
            ..clear()
            ..add(i);
        }
      }
      // 5-6 photos : la mise en avant est ignorée (grille égale) — pas
      // d'action, le message dédié l'explique dans l'UI (_buildCollageStep).
    });
  }

  String get _orientation =>
      _layout.orientation == PosterOrientation.landscape ? 'landscape' : 'portrait';

  Future<void> _placeOrder() async {
    final quality = _quality[_size];
    if (quality == null || quality.verdict == PosterQualityVerdict.disabled) {
      _showSnack('Cette taille n\'est pas assez nette avec ces photos — choisis une taille plus petite.');
      return;
    }
    final isEdit = widget.editOrderId != null;
    if (!isEdit && !(_addressKey.currentState?.validate() ?? false)) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _ordering = true;
      _orderMessage = 'Préparation des vidéos liées…';
    });
    try {
      // 1. "Reel" vidéo public (cible du QR) — créé AVANT le PDF puisque le QR
      // doit déjà être imprimé dedans.
      final reelRes = await BackendClient.postJson(
        '/api/video/poster-reel-create',
        {'memoryIds': _memories.map((m) => m.id).toList()},
        timeout: const Duration(seconds: 20),
      );
      final reelId = reelRes?['reelId'] as String?;
      if (reelId == null) {
        throw Exception('Impossible de préparer les vidéos liées au poster.');
      }
      final qrUrl = '${AppConfig.backendUrl}/api/video/poster-video-reel?o=$reelId';

      if (!mounted) return;
      setState(() => _orderMessage = 'Génération du poster…');

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
        bookTitle: 'Poster $_size',
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
        memoryCount: _memories.length,
        pdfUrl: uploaded.url,
        productType: 'poster',
        posterSku: entry?.sku,
        posterSize: _size,
        posterOrientation: _orientation,
        posterHangerColor: _color,
        posterCaption: _captionCtrl.text.trim().isNotEmpty ? _captionCtrl.text.trim() : null,
        posterMemoryIds: _memories.map((m) => m.id).toList(),
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
        title: const Text('Créer le poster',
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

  Widget _buildCollageStep() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        AspectRatio(
          aspectRatio: _layout.orientation == PosterOrientation.landscape ? 4 / 3 : 3 / 4,
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
                  return Stack(
                    children: [
                      for (var i = 0;
                          i < _layout.tiles.length && i < _photoUrls.length;
                          i++)
                        Positioned(
                          left: _layout.tiles[i].x * w,
                          top: _layout.tiles[i].y * h,
                          width: _layout.tiles[i].w * w,
                          height: _layout.tiles[i].h * h,
                          child: _CollageTile(
                            url: _photoUrls[i],
                            featured: _featured.contains(i),
                            selectable: _memories.length <= 4,
                            onTap: () => _toggleFeatured(i),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _memories.length <= 4
              ? (_memories.length == 1
                  ? 'Une seule photo — plein cadre.'
                  : 'Tape une photo pour la mettre en avant.')
              : 'Au-delà de 4 photos, toutes les photos sont affichées à la même taille.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12.5, color: AppColors.textMedium),
        ),
        const SizedBox(height: 24),
        const Text('Texte sur le poster (optionnel)',
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
        const Text(
          'Affiché dans la bande du bas, à côté du QR code (vidéos des souvenirs choisis).',
          style: TextStyle(fontSize: 11.5, color: AppColors.textMedium),
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        const Text('Taille',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
        const SizedBox(height: 10),
        for (final size in PosterPricing.sizes)
          _SizeCard(
            size: size,
            quality: quality[size],
            price: PosterPricing.price(size, _orientation),
            selected: _size == size,
            onTap: () {
              final q = quality[size];
              if (q == null || q.verdict == PosterQualityVerdict.disabled) {
                final detail = q?.achievableDpi != null
                    ? ' (photo la plus limitante : qualité insuffisante à cette taille)'
                    : ' (indisponible pour cette orientation)';
                _showSnack('Taille $size trop juste avec ces photos$detail.');
                return;
              }
              setState(() => _size = size);
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
          onPressed: () => setState(() => _step = 2),
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
                  'Poster $_size · ${_orientation == 'landscape' ? 'Paysage' : 'Portrait'} · ${PosterPricing.hangerColorLabel(_color)}',
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

class _CollageTile extends StatelessWidget {
  final String url;
  final bool featured;
  final bool selectable;
  final VoidCallback onTap;
  const _CollageTile({
    required this.url,
    required this.featured,
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
          border: featured ? Border.all(color: Colors.white, width: 3) : null,
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
            if (featured)
              const Positioned(
                right: 4,
                top: 4,
                child: Icon(Icons.star, color: Colors.white, size: 18,
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
  final double? price;
  final bool selected;
  final VoidCallback onTap;
  const _SizeCard({
    required this.size,
    required this.quality,
    required this.price,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = quality == null || quality!.verdict == PosterQualityVerdict.disabled;
    final badge = switch (quality?.verdict) {
      PosterQualityVerdict.ok => ('✅', AppColors.sage, 'Qualité parfaite'),
      PosterQualityVerdict.limited => ('⚠️', AppColors.amber, 'Qualité limite'),
      _ => ('🚫', AppColors.error, 'Indisponible'),
    };
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
                    Text(badge.$3, style: TextStyle(fontSize: 11.5, color: badge.$2)),
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
