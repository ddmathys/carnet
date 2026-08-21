import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:printing/printing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/services/order_service.dart';

// ── PDF preview viewer — affiche les pages du VRAI PDF (rastérisées) ──────────
// L'aperçu est strictement identique au fichier téléchargé / envoyé à
// l'impression : on génère les mêmes octets PDF puis on rastérise chaque
// page à la demande.

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
  });

  @override
  State<PdfPreviewViewer> createState() => _PdfPreviewViewerState();
}

class _PdfPreviewViewerState extends State<PdfPreviewViewer> {
  late final PageController _ctrl;
  int _current = 0;

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

  // Format du document d'impression (A4 210 × 297 mm, cf. BookPdfService) →
  // ratio des cartes de page.
  static const double _pageAspect = 210 / 297;

  @override
  void initState() {
    super.initState();
    _ctrl = PageController();
    _ctrl.addListener(() {
      final p = _ctrl.page?.round() ?? 0;
      if (p != _current && mounted) setState(() => _current = p);
    });
  }

  @override
  void didUpdateWidget(covariant PdfPreviewViewer old) {
    super.didUpdateWidget(old);
    // Nouveau PDF (sélection/titre modifiés) → on jette le cache.
    if (!identical(old.pdfBytes, widget.pdfBytes)) {
      _cache.clear();
      _inflight.clear();
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Page counter
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            '${_current + 1} / ${widget.pageCount}',
            style: const TextStyle(color: AppColors.textMedium, fontSize: 13),
          ),
        ),
        // PageView
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: PageView.builder(
              controller: _ctrl,
              itemCount: widget.pageCount,
              itemBuilder: (_, i) => _PdfPageCard(
                aspect: _pageAspect,
                future: _rasterPage(i),
              ),
            ),
          ),
        ),
        // Dot indicators
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              widget.pageCount.clamp(0, 20),
              (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _current ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: i == _current
                      ? AppColors.sage
                      : AppColors.softGray.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
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
                onPressed: widget.onDownload,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Télécharger le PDF'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: widget.onChooseFormat,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                child: const Text('Choisir le format →'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Une page du PDF rastérisée, dans une carte blanche au ratio du document.
class _PdfPageCard extends StatelessWidget {
  final double aspect;
  final Future<Uint8List> future;

  const _PdfPageCard({required this.aspect, required this.future});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(12),
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
          child: FutureBuilder<Uint8List>(
            future: future,
            builder: (_, snap) {
              if (snap.hasData) {
                return Image.memory(snap.data!, fit: BoxFit.cover);
              }
              if (snap.hasError) {
                return const Center(
                  child: Icon(Icons.broken_image_outlined,
                      color: AppColors.softGray, size: 28),
                );
              }
              return const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            },
          ),
        ),
      ),
    );
  }
}
