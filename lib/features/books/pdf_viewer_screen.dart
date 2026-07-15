import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:printing/printing.dart';
import '../../core/theme/app_theme.dart';

/// Visualiseur PDF PLEIN ÉCRAN, dans l'app. On voit le livre page par page sans
/// passer par la feuille de partage du système ; le bouton partager/imprimer
/// reste disponible en haut. Sert après la génération d'un PDF et depuis
/// « Mes livres ».
///
/// La source est soit des octets déjà en main (PDF fraîchement généré), soit une
/// URL (livre de l'historique, à télécharger). L'URL des livres est une URL
/// backend stable qui redirige vers R2 signé — voir PdfService.
class PdfViewerScreen extends StatefulWidget {
  final String title;
  final Uint8List? bytes;
  final String? url;

  const PdfViewerScreen({super.key, required this.title, this.bytes, this.url})
      : assert(bytes != null || url != null,
            'Fournir des octets ou une URL de PDF');

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bytes = widget.bytes;
    if (_bytes == null) _load();
  }

  Future<void> _load() async {
    try {
      final res = await http
          .get(Uri.parse(widget.url!))
          .timeout(const Duration(seconds: 40));
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      if (!mounted) return;
      setState(() => _bytes = res.bodyBytes);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String get _filename => '${widget.title.replaceAll(RegExp(r'\s+'), '_')}.pdf';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textDark),
        title: Text(
          widget.title,
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontWeight: FontWeight.w600,
            color: AppColors.textDark,
            fontSize: 18,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _error != null
          ? _errorState()
          : _bytes == null
              ? const Center(child: CircularProgressIndicator())
              : PdfPreview(
                  build: (_) => _bytes!,
                  pdfFileName: _filename,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  // On garde le partage/impression accessibles, mais la lecture
                  // se fait ICI, dans l'app.
                  allowSharing: true,
                  allowPrinting: true,
                  loadingWidget: const CircularProgressIndicator(),
                  previewPageMargin: const EdgeInsets.all(8),
                  scrollViewDecoration:
                      const BoxDecoration(color: AppColors.background),
                ),
    );
  }

  Widget _errorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_as_pdf_outlined,
                color: AppColors.softGray, size: 44),
            const SizedBox(height: 12),
            const Text('Impossible d\'ouvrir le PDF.',
                style: TextStyle(color: AppColors.textMedium)),
            const SizedBox(height: 6),
            Text(_error ?? '',
                style:
                    const TextStyle(color: AppColors.softGray, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                setState(() => _error = null);
                _load();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}
