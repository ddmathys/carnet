import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/poster_template.dart';
import '../utils/bounded_concurrency.dart';
import 'poster_pricing.dart';

/// Génère le PDF plein cadre d'un poster (produit "Art print with hanger") —
/// équivalent poster de BookPdfService, mais une seule page. Voir le plan
/// `eager-pondering-pony.md` pour le détail des templates de collage.
class PosterPdfService {
  static const _cream = PdfColor(0.980, 0.965, 0.933);
  static const _textDark = PdfColor(0.176, 0.141, 0.086);

  // Bande du bas (texte + QR) : fraction de la hauteur de page réservée,
  // suffisante pour rester lisible du A4 au A0. Définie dans
  // poster_template.dart car PosterFormatRules en a besoin aussi (la place
  // qui reste aux cases décide du format minimum).
  static const double _bandFraction = posterBandFraction;

  /// Télécharge les octets de chaque photo (URL déjà résolue — R2 signée ou
  /// Firebase), même pattern que BookPdfService : concurrence bornée, un
  /// retry global, échec franc si des photos manquent encore après —
  /// contrairement à l'aperçu, un poster à l'impression ne doit jamais
  /// partir avec une case vide sans que personne ne le voie.
  static Future<List<Uint8List>> downloadPhotoBytes(List<String> urls) async {
    Future<Map<String, Uint8List>> fetchAll(Iterable<String> u) async {
      final results = await runBounded<String, Uint8List?>(
        u.toList(),
        (url) async {
          try {
            final response =
                await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
            return response.statusCode == 200 ? response.bodyBytes : null;
          } catch (_) {
            return null;
          }
        },
        concurrency: 6,
      );
      final map = <String, Uint8List>{};
      for (var i = 0; i < results.length; i++) {
        final bytes = results[i];
        if (bytes != null) map[u.elementAt(i)] = bytes;
      }
      return map;
    }

    final byUrl = await fetchAll(urls);
    var missing = urls.where((u) => !byUrl.containsKey(u)).toList();
    if (missing.isNotEmpty) {
      byUrl.addAll(await fetchAll(missing));
      missing = urls.where((u) => !byUrl.containsKey(u)).toList();
      if (missing.isNotEmpty) {
        throw Exception(
            '${missing.length} photo(s) n\'ont pas pu être téléchargées — '
            'vérifie ta connexion et réessaie.');
      }
    }
    return [for (final u in urls) byUrl[u]!];
  }

  /// `photoBytes` doit avoir le MÊME ORDRE/longueur que `layout.tiles`.
  static Future<Uint8List> generate({
    required List<Uint8List> photoBytes,
    required PosterLayout layout,
    required String size,
    required String orientation,
    String? caption,
    // null = pas de vidéo/mémo vocal parmi les souvenirs choisis : pas de QR
    // imprimé (un code qui ne mène nulle part n'a aucune valeur pour le
    // destinataire). Décidé par l'appelant (poster_generate_screen.dart).
    String? qrUrl,
  }) async {
    assert(photoBytes.length == layout.tiles.length);
    final mm = PosterPricing.mmFor(size, orientation);
    if (mm == null) {
      throw ArgumentError('Taille/orientation invalide : $size / $orientation');
    }
    final pageW = mm.wMm * PdfPageFormat.mm;
    final pageH = mm.hMm * PdfPageFormat.mm;
    final contentH = pageH * (1 - _bandFraction);
    final bandH = pageH * _bandFraction;

    final playfairB = pw.Font.ttf(
        await rootBundle.load('assets/fonts/PlayfairDisplay-Bold.ttf'));

    final doc = pw.Document(title: 'Tirage $size', author: 'Carnet');

    final tiles = <pw.Widget>[];
    for (var i = 0; i < layout.tiles.length; i++) {
      final t = layout.tiles[i];
      tiles.add(pw.Positioned(
        left: t.x * pageW,
        top: t.y * contentH,
        child: pw.SizedBox(
          width: t.w * pageW,
          height: t.h * contentH,
          child: pw.Image(pw.MemoryImage(photoBytes[i]), fit: pw.BoxFit.cover),
        ),
      ));
    }

    final trimmedCaption = caption?.trim() ?? '';
    final qrSize = bandH * 0.78;

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(pageW, pageH, marginAll: 0),
      build: (_) => pw.Stack(children: [
        pw.Positioned(
          left: 0,
          top: 0,
          child: pw.Container(width: pageW, height: contentH, color: _cream),
        ),
        ...tiles,
        pw.Positioned(
          left: 0,
          top: contentH,
          child: pw.Container(
            width: pageW,
            height: bandH,
            color: PdfColors.white,
            padding: pw.EdgeInsets.symmetric(
                horizontal: pageW * 0.025, vertical: bandH * 0.14),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Expanded(
                  child: trimmedCaption.isEmpty
                      ? pw.SizedBox()
                      : pw.Text(
                          trimmedCaption,
                          maxLines: 2,
                          overflow: pw.TextOverflow.clip,
                          style: pw.TextStyle(
                            font: playfairB,
                            fontSize: bandH * 0.24,
                            color: _textDark,
                          ),
                        ),
                ),
                if (qrUrl != null) ...[
                  pw.SizedBox(width: bandH * 0.15),
                  pw.BarcodeWidget(
                    barcode: pw.Barcode.qrCode(),
                    data: qrUrl,
                    width: qrSize,
                    height: qrSize,
                    color: _textDark,
                  ),
                ],
              ],
            ),
          ),
        ),
      ]),
    ));

    return doc.save();
  }
}
