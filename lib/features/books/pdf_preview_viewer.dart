import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:printing/printing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/services/order_service.dart';

// ── PDF preview viewer — affiche les pages du VRAI PDF (rastérisées) ──────────
// L'aperçu est strictement identique au fichier téléchargé / envoyé à
// l'impression : on génère les mêmes octets PDF puis on rastérise chaque
// page à la demande.
//
// C'est aussi l'ÉDITEUR du livre : toucher une photo (repérée grâce au plan
// `slots` fourni par BookPdfService) ouvre ses réglages chez le parent
// (`onPhotoTap`) — texte sur la photo, retrait, mise en grand. Le parent
// régénère alors le PDF ; pendant ce temps, les pages déjà affichées restent
// visibles (pas d'écran vide à chaque retouche).

class PdfPreviewViewer extends StatefulWidget {
  final Uint8List pdfBytes;
  final int pageCount;
  // Infos pages/prix affichées en lecture seule sur cet écran (mêmes valeurs
  // que l'étape format juste après — juste visibles plus tôt, sans y aller).
  // Nombre de pages RÉEL, calculé séparément par format (souple ≥20, rigide
  // ≥24 — voir _printedPagesFor) : un même livre peut être imprimé sur un
  // nombre de pages différent selon la couverture choisie.
  final int photoCount;
  final int pagesSoft;
  final int pagesHard;
  final String priceSoft;
  final String priceHard;
  final bool exceedsLimit;
  final VoidCallback onDownload;
  final VoidCallback onChooseFormat;

  /// Plan des photos (page, case) du PDF affiché.
  final List<BookPhotoSlot> slots;
  final ValueChanged<BookPhotoSlot>? onPhotoTap;

  /// Vrai pendant qu'une retouche est en train d'être appliquée au PDF.
  final bool updating;

  /// Photos retirées du livre depuis l'éditeur, et de quoi les remettre.
  final int removedCount;
  final VoidCallback? onRestoreRemoved;

  const PdfPreviewViewer({
    super.key,
    required this.pdfBytes,
    required this.pageCount,
    required this.photoCount,
    required this.pagesSoft,
    required this.pagesHard,
    required this.priceSoft,
    required this.priceHard,
    required this.exceedsLimit,
    required this.onDownload,
    required this.onChooseFormat,
    this.slots = const [],
    this.onPhotoTap,
    this.updating = false,
    this.removedCount = 0,
    this.onRestoreRemoved,
  });

  @override
  State<PdfPreviewViewer> createState() => _PdfPreviewViewerState();
}

class _PdfPreviewViewerState extends State<PdfPreviewViewer> {
  late PageController _ctrl;
  int _current = 0;
  // Vue d'ensemble (grille de toutes les pages) plutôt que page par page.
  bool _grid = false;

  bool get _isAdmin =>
      FirebaseAuth.instance.currentUser?.email == AppConfig.adminEmail;
  bool _checkingProdigi = false;
  String? _prodigiResultText;
  String? _prodigiErrorText;

  // Même vérification que dans la console admin (POST /api/prodigi/quote,
  // gratuit, ne modifie rien) — mais ici pour les DEUX formats d'un coup
  // (souple et rigide), vu que l'aperçu les affiche déjà côte à côte.
  Future<void> _verifyProdigi() async {
    setState(() {
      _checkingProdigi = true;
      _prodigiResultText = null;
      _prodigiErrorText = null;
    });
    try {
      final results = await Future.wait([
        OrderService.verifyPrintQuote(
            coverType: 'soft', pageCount: widget.pagesSoft),
        OrderService.verifyPrintQuote(
            coverType: 'hard', pageCount: widget.pagesHard),
      ]);
      if (!mounted) return;
      String fmt(Map<String, dynamic> r) {
        final usd = (r['prodigiCostUsd'] as num?)?.toStringAsFixed(2);
        return usd != null ? '\$$usd' : 'non lisible';
      }
      setState(() {
        _prodigiResultText =
            'Coût Prodigi réel — Souple ${fmt(results[0])} · Rigide ${fmt(results[1])}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _prodigiErrorText = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _checkingProdigi = false);
    }
  }

  // Cache des pages déjà rastérisées (index → PNG).
  final Map<int, Uint8List> _cache = {};
  final Map<int, Future<Uint8List>> _inflight = {};
  // Pages du PDF PRÉCÉDENT, affichées le temps que les nouvelles se
  // rastérisent après une retouche.
  Map<int, Uint8List> _stale = {};

  // Format du document d'impression (A4 210 × 297 mm, cf. BookPdfService) →
  // ratio des cartes de page.
  static const double _pageAspect = 210 / 297;

  @override
  void initState() {
    super.initState();
    _ctrl = _newController(0);
  }

  PageController _newController(int page) {
    final c = PageController(initialPage: page);
    c.addListener(() {
      final p = c.page?.round() ?? 0;
      if (p != _current && mounted) setState(() => _current = p);
    });
    return c;
  }

  @override
  void didUpdateWidget(covariant PdfPreviewViewer old) {
    super.didUpdateWidget(old);
    // Nouveau PDF (retouche, sélection, titre) → nouveau rendu, en gardant
    // l'ancien à l'écran en attendant.
    if (!identical(old.pdfBytes, widget.pdfBytes)) {
      _stale = {..._stale, ..._cache};
      _cache.clear();
      _inflight.clear();
      if (_current >= widget.pageCount && widget.pageCount > 0) {
        _current = widget.pageCount - 1;
      }
    }
  }

  void _openPage(int index) {
    _ctrl.dispose();
    setState(() {
      _current = index;
      _ctrl = _newController(index);
      _grid = false;
    });
  }

  // Touché sur la page `index` à la position relative (fx, fy) ∈ [0, 1].
  void _onPageTap(int index, double fx, double fy) {
    if (widget.onPhotoTap == null) return;
    for (final s in widget.slots) {
      if (s.pageIndex == index && s.contains(fx, fy)) {
        widget.onPhotoTap!(s);
        return;
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Rastérise une page (résolution adaptée à un écran de téléphone) et garde le
  // résultat en cache. Les appels concurrents sur la même page sont fusionnés.
  Future<Uint8List> _rasterPage(int index) {
    final cached = _cache[index];
    if (cached != null) return Future.value(cached);
    return _inflight[index] ??= () async {
      final raster = await Printing.raster(
        widget.pdfBytes,
        pages: [index],
        dpi: 140,
      ).first;
      final png = await raster.toPng();
      if (mounted) _cache[index] = png;
      _inflight.remove(index);
      return png;
    }();
  }

  Widget _pageCard(int i, {bool interactive = true}) => _PdfPageCard(
        key: ValueKey('page-$i-${identityHashCode(widget.pdfBytes)}'),
        aspect: _pageAspect,
        future: _rasterPage(i),
        placeholder: _stale[i],
        onTapAt: interactive ? (fx, fy) => _onPageTap(i, fx, fy) : null,
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Barre : compteur de pages / état de mise à jour / vue d'ensemble
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 8, 0),
          child: Row(
            children: [
              if (widget.updating) ...[
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                const Text('Mise à jour…',
                    style:
                        TextStyle(color: AppColors.textMedium, fontSize: 13)),
              ] else
                Text(
                  _grid
                      ? '${widget.pageCount} pages'
                      : 'Page ${_current + 1} / ${widget.pageCount}',
                  style: const TextStyle(
                      color: AppColors.textMedium, fontSize: 13),
                ),
              const Spacer(),
              TextButton.icon(
                onPressed: () =>
                    _grid ? _openPage(_current) : setState(() => _grid = true),
                icon: Icon(
                    _grid ? Icons.crop_portrait : Icons.grid_view_rounded,
                    size: 18),
                label: Text(_grid ? 'Page par page' : 'Vue d\'ensemble',
                    style: const TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                    foregroundColor: AppColors.textMedium),
              ),
            ],
          ),
        ),
        if (widget.onPhotoTap != null && !_grid)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Text(
              'Touche une photo pour y écrire un texte, la mettre en grand '
              'ou la retirer du livre.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.softGray, fontSize: 12),
            ),
          ),
        Expanded(
          child: _grid
              ? GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: _pageAspect,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: widget.pageCount,
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () => _openPage(i),
                    child: _pageCard(i, interactive: false),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: PageView.builder(
                    controller: _ctrl,
                    itemCount: widget.pageCount,
                    itemBuilder: (_, i) => _pageCard(i),
                  ),
                ),
        ),
        if (widget.removedCount > 0 && widget.onRestoreRemoved != null)
          TextButton.icon(
            onPressed: widget.updating ? null : widget.onRestoreRemoved,
            icon: const Icon(Icons.restore, size: 16),
            label: Text(
              widget.removedCount == 1
                  ? '1 photo retirée — la remettre'
                  : '${widget.removedCount} photos retirées — les remettre',
              style: const TextStyle(fontSize: 12.5),
            ),
            style: TextButton.styleFrom(foregroundColor: AppColors.textMedium),
          )
        else
          const SizedBox(height: 8),
        // Photos / pages / prix — mêmes valeurs qu'à l'étape format, visibles
        // ici sans avoir à y aller. Pages et prix affichés séparément par
        // format (souple/rigide n'ont pas le même minimum de pages, donc pas
        // forcément le même nombre de pages imprimées pour ce livre).
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: widget.exceedsLimit
              ? const Text(
                  'Ce livre dépasse 300 pages : retire des souvenirs pour '
                  'pouvoir l\'imprimer.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.amber, fontSize: 12.5),
                )
              : Text(
                  '${widget.photoCount} photos\n'
                  'Souple · ${widget.pagesSoft} pages · ${widget.priceSoft}\n'
                  'Rigide · ${widget.pagesHard} pages · ${widget.priceHard}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textMedium,
                      fontSize: 12.5,
                      height: 1.5),
                ),
        ),
        // Vérification du prix/pages contre un vrai devis Prodigi (admin
        // uniquement — le backend refuse l'appel sinon).
        if (_isAdmin && !widget.exceedsLimit) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                OutlinedButton.icon(
                  onPressed: _checkingProdigi ? null : _verifyProdigi,
                  icon: _checkingProdigi
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.fact_check_outlined, size: 16),
                  label: const Text('Vérifier chez Prodigi',
                      style: TextStyle(fontSize: 12.5)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.amber,
                    side: const BorderSide(color: AppColors.amber),
                    minimumSize: const Size(0, 34),
                  ),
                ),
                if (_prodigiResultText != null) ...[
                  const SizedBox(height: 6),
                  Text(_prodigiResultText!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textMedium)),
                ],
                if (_prodigiErrorText != null) ...[
                  const SizedBox(height: 6),
                  Text(_prodigiErrorText!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.error)),
                ],
              ],
            ),
          ),
        ],
        // CTA
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          child: Column(
            children: [
              OutlinedButton.icon(
                onPressed: widget.updating ? null : widget.onDownload,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Télécharger le PDF'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: widget.updating ? null : widget.onChooseFormat,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                child: const Text('Valider le livre →'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Une page du PDF rastérisée, dans une carte blanche au ratio du document.
// `placeholder` : rendu précédent de la page, affiché en attendant le nouveau.
// `onTapAt` : position relative (0..1) du toucher sur la page.
class _PdfPageCard extends StatelessWidget {
  final double aspect;
  final Future<Uint8List> future;
  final Uint8List? placeholder;
  final void Function(double fx, double fy)? onTapAt;

  const _PdfPageCard({
    super.key,
    required this.aspect,
    required this.future,
    this.placeholder,
    this.onTapAt,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: AspectRatio(
          aspectRatio: aspect,
          child: LayoutBuilder(
            builder: (_, box) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: onTapAt == null
                  ? null
                  : (d) => onTapAt!(d.localPosition.dx / box.maxWidth,
                      d.localPosition.dy / box.maxHeight),
              child: FutureBuilder<Uint8List>(
                future: future,
                builder: (_, snap) {
                  if (snap.hasData) {
                    return Image.memory(snap.data!,
                        fit: BoxFit.cover, gaplessPlayback: true);
                  }
                  if (snap.hasError) {
                    return const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: AppColors.softGray, size: 28),
                    );
                  }
                  if (placeholder != null) {
                    return Image.memory(placeholder!,
                        fit: BoxFit.cover, gaplessPlayback: true);
                  }
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
