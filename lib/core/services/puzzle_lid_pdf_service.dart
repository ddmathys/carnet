import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'puzzle_pricing.dart';

/// Compose le COUVERCLE de la boîte métal du puzzle : la photo, plus un
/// bandeau portant le titre du souvenir et un QR code vers ses vidéos et
/// mémos vocaux.
///
/// Pourquoi (06.10.26) : jusqu'ici la zone d'impression `lid` recevait
/// exactement la même photo que le puzzle lui-même (voir
/// backend/api/prodigi/[action].ts) — surface gâchée, alors que c'est la
/// seule partie de l'objet qu'on regarde avant de l'ouvrir. C'est aussi le
/// différenciateur qui justifie le tarif premium : aucun concurrent suisse ne
/// vend un puzzle dont la boîte fait jouer les vidéos du souvenir.
///
/// ⚠️ Contrainte non négociable : la page est générée EXACTEMENT aux
/// proportions de la zone d'impression du couvercle
/// (`PuzzleCatalogEntry.lidPrintAreaPx*`, relevées dans la fiche produit
/// Prodigi). `sizing` est défini au niveau de l'ARTICLE chez Prodigi, pas de
/// l'asset : le couvercle subit donc le même `fillPrintArea` que le puzzle.
/// À proportions identiques, ce recadrage ne retire rien ; à proportions
/// différentes, il rognerait — et couperait le QR.
class PuzzleLidPdfService {
  static const _cream = PdfColor(0.980, 0.965, 0.933);
  static const _textDark = PdfColor(0.176, 0.141, 0.086);

  /// Hauteur du bandeau du bas, en fraction de la hauteur du couvercle.
  /// Plus généreux que le bandeau du poster (12 %) : le couvercle est petit
  /// (202 × 167 mm pour un 1000 pièces) et le QR doit rester scannable.
  static const double _bandFraction = 0.22;

  /// Largeur de page en points. Le couvercle réel fait au plus 202 mm de
  /// large ; on génère à 1000 pt (~352 mm) pour garder de la marge de
  /// rééchantillonnage, la hauteur suivant le ratio exact de la zone.
  static const double _pageWidthPt = 1000;

  /// [qrUrl] null = le souvenir n'a ni vidéo ni mémo vocal : aucun QR n'est
  /// imprimé, comme pour le poster. On n'imprime jamais un code mort.
  static Future<Uint8List> generate({
    required Uint8List photoBytes,
    required String size,
    String? caption,
    String? qrUrl,
  }) async {
    final entry = PuzzlePricing.entryFor(size);
    if (entry == null) {
      throw ArgumentError('Taille de puzzle inconnue : $size');
    }

    const pageW = _pageWidthPt;
    final pageH = pageW / entry.lidAspect;
    final bandH = pageH * _bandFraction;
    final photoH = pageH - bandH;

    final doc = pw.Document();
    final playfairB = pw.Font.ttf(
        await rootBundle.load('assets/fonts/PlayfairDisplay-Bold.ttf'));

    final trimmedCaption = caption?.trim() ?? '';
    final qrSize = bandH * 0.74;

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(pageW, pageH, marginAll: 0),
      build: (_) => pw.Stack(children: [
        // Fond : visible uniquement si la photo ne couvre pas tout (elle
        // couvre toujours, `BoxFit.cover`), mais évite un liseré blanc au
        // rendu si l'imprimeur applique une marge de sécurité.
        pw.Positioned(
          left: 0,
          top: 0,
          child: pw.Container(width: pageW, height: pageH, color: _cream),
        ),
        pw.Positioned(
          left: 0,
          top: 0,
          child: pw.SizedBox(
            width: pageW,
            height: photoH,
            child: pw.Image(pw.MemoryImage(photoBytes), fit: pw.BoxFit.cover),
          ),
        ),
        pw.Positioned(
          left: 0,
          top: photoH,
          child: pw.Container(
            width: pageW,
            height: bandH,
            color: PdfColors.white,
            padding: pw.EdgeInsets.symmetric(
                horizontal: pageW * 0.03, vertical: bandH * 0.13),
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
                            fontSize: bandH * 0.26,
                            color: _textDark,
                          ),
                        ),
                ),
                if (qrUrl != null) ...[
                  pw.SizedBox(width: bandH * 0.14),
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
