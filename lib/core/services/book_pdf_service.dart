import 'dart:math' show min, max;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/child_model.dart';
import '../models/notebook_model.dart';
import '../models/book_chapter.dart';
import '../models/milestone_model.dart';
import '../models/memory_model.dart';
import '../utils/date_precision.dart';

class BookPdfService {
  static const _cream = PdfColor(0.980, 0.965, 0.933);
  static const _textDark = PdfColor(0.176, 0.141, 0.086);
  static const _textMedium = PdfColor(0.55, 0.55, 0.55);

  // Format « print-ready » Gelato : livre photo softcover 21×28 cm (Gelato n'a
  // pas d'A4 en livre photo ; 21×28 est le portrait le plus proche) + 4 mm de
  // fond perdu (bleed) sur chaque côté → document 218×288 mm. Les images
  // remplissent tout le document ; texte / QR / numéro de page sont rentrés
  // d'au moins _bleed pour rester dans la zone de sécurité après coupe.
  static const _bleed = 0.4 * PdfPageFormat.cm; // 4 mm
  static const _a4W = 21.0 * PdfPageFormat.cm + 2 * _bleed; // 218 mm (doc)
  static const _a4H = 28.0 * PdfPageFormat.cm + 2 * _bleed; // 288 mm (doc)

  static PdfColor _toPdf(Color c) =>
      PdfColor(c.red / 255.0, c.green / 255.0, c.blue / 255.0);

  static PdfColor _toPdfWithAlpha(Color c, double alpha) =>
      PdfColor(c.red / 255.0, c.green / 255.0, c.blue / 255.0, alpha);

  static Future<Uint8List> generate({
    required ChildModel child,
    required String animalId,
    required Color coverColor,
    required List<BookChapter> chapters,
    required List<MilestoneModel> growthMilestones,
  }) async {
    final playfairR = pw.Font.ttf(
        await rootBundle.load('assets/fonts/PlayfairDisplay-Regular.ttf'));
    final playfairB = pw.Font.ttf(
        await rootBundle.load('assets/fonts/PlayfairDisplay-Bold.ttf'));
    final dmSans = pw.Font.ttf(
        await rootBundle.load('assets/fonts/DMSans-Regular.ttf'));

    String? svgString;
    try {
      svgString =
          await rootBundle.loadString('assets/images/animals/$animalId.svg');
    } catch (_) {}

    final pdfCover = _toPdf(coverColor);
    final hasGrowth = growthMilestones.length >= 2;
    final totalPages = 1 + chapters.length + (hasGrowth ? 1 : 0);
    const roman = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII'];
    const fmt = PdfPageFormat.a5;

    Future<Uint8List> buildAndSave(String? svg) async {
      final doc = pw.Document(
        title: 'Le livre de ${child.firstName}',
        author: 'Folio',
      );

      doc.addPage(pw.Page(
        pageFormat: fmt,
        build: (_) => _coverPage(
          child: child,
          svgString: svg,
          cover: pdfCover,
          pR: playfairR,
          pB: playfairB,
        ),
      ));

      for (int i = 0; i < chapters.length; i++) {
        doc.addPage(pw.Page(
          pageFormat: fmt,
          build: (_) => _chapterPage(
            chapter: chapters[i],
            idx: i,
            cover: pdfCover,
            pR: playfairR,
            pB: playfairB,
            dm: dmSans,
            pageNum: i + 2,
            total: totalPages,
            roman: roman,
          ),
        ));
      }

      if (hasGrowth) {
        doc.addPage(pw.Page(
          pageFormat: fmt,
          build: (_) => _growthPage(
            child: child,
            milestones: growthMilestones,
            cover: pdfCover,
            coverFlutter: coverColor,
            pB: playfairB,
            dm: dmSans,
            pageNum: totalPages,
            total: totalPages,
          ),
        ));
      }

      return doc.save();
    }

    // Try with SVG first; if rendering fails fall back to no image.
    if (svgString != null) {
      try {
        return await buildAndSave(svgString);
      } catch (_) {
        return await buildAndSave(null);
      }
    }
    return buildAndSave(null);
  }

  // ── Notebook version (multi-template) ─────────────────────────────────────

  static Future<({Uint8List bytes, int pageCount})> generateForNotebook({
    required NotebookModel notebook,
    required Color coverColor,
    required List<MemoryModel> memories,
    Map<String, String> locationComments = const {},
    String? coverPhotoUrl,
    String? customTitle,
    String? customSubtitle,
    String backendUrl = '',
    bool padForPrint = false,
    bool excludeCoverPhotoFromBook = false,
  }) async {
    final playfairR = pw.Font.ttf(
        await rootBundle.load('assets/fonts/PlayfairDisplay-Regular.ttf'));
    final playfairB = pw.Font.ttf(
        await rootBundle.load('assets/fonts/PlayfairDisplay-Bold.ttf'));
    final dmSans = pw.Font.ttf(
        await rootBundle.load('assets/fonts/DMSans-Regular.ttf'));

    String? svgString;
    if (notebook.type == 'enfant' && notebook.companion != null) {
      try {
        svgString = await rootBundle
            .loadString('assets/images/animals/${notebook.companion}.svg');
      } catch (_) {}
    }

    // Build flat list of (memory, photoUrl) sorted chronologically
    final photoEntries = <_PhotoEntry>[];
    final sorted = [...memories]..sort((a, b) => a.date.compareTo(b.date));
    for (final m in sorted) {
      final urls = m.mediaUrls.isNotEmpty
          ? m.mediaUrls
          : (m.photoUrl != null && m.photoUrl!.isNotEmpty ? [m.photoUrl!] : <String>[]);
      for (final url in urls) {
        photoEntries.add(_PhotoEntry(memory: m, url: url));
      }
    }

    // Download all photo bytes in parallel (cover photo included)
    final Map<String, Uint8List> bytesByUrl = {};
    final urlsToFetch = {
      ...photoEntries.map((e) => e.url),
      if (coverPhotoUrl != null) coverPhotoUrl,
    }.toList();
    await Future.wait(urlsToFetch.map((url) async {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) bytesByUrl[url] = response.bodyBytes;
      } catch (_) {}
    }));

    final coverPhotoBytes = coverPhotoUrl != null ? bytesByUrl[coverPhotoUrl] : null;
    // Photos affichées dans le livre. Option : exclure la photo de couverture
    // pour ne pas la répéter à l'intérieur.
    final successfulPhotos = photoEntries.where((e) {
      if (!bytesByUrl.containsKey(e.url)) return false;
      if (excludeCoverPhotoFromBook &&
          coverPhotoUrl != null &&
          e.url == coverPhotoUrl) return false;
      return true;
    }).toList();
    final shownPhotoMemoIds = successfulPhotos.map((e) => e.memory.id).toSet();

    // Souvenirs en page texte : ceux sans photo affichée (jamais de photo, ou
    // dont la seule photo était la couverture exclue / un download échoué).
    final textOnlyMemories = sorted.where((m) {
      if (m.type == 'taille_poids') return false;
      final hasPhoto = m.mediaUrls.isNotEmpty ||
          (m.photoUrl != null && m.photoUrl!.isNotEmpty);
      if (!hasPhoto) return true;
      return !shownPhotoMemoIds.contains(m.id);
    }).toList();

    // Year range from actual memory dates
    final years = sorted.map((m) => m.date.year).toSet();
    final minYear = years.isEmpty ? DateTime.now().year : years.reduce(min);
    final maxYear = years.isEmpty ? DateTime.now().year : years.reduce(max);
    final yearRange = minYear == maxYear ? '$minYear' : '$minYear — $maxYear';

    // Up to 5 memory titles for cover subtitle
    final highlights = _coverHighlights(sorted);

    // Orientation de chaque photo : portrait → page pleine, paysage → demi-page.
    // Dimensions de chaque photo → orientation + éligibilité « pleine page ».
    // Une photo portrait ne passe en PLEINE PAGE que si elle est assez nette
    // (largeur ≥ _fullPageMinWidthPx) ; sinon, agrandie plein cadre elle serait
    // pixelisée → on la met en demi-page (plus petite, défaut moins visible).
    final dimsList =
        successfulPhotos.map((e) => _imgDims(bytesByUrl[e.url]!)).toList();
    bool isPortraitAt(int i) {
      final d = dimsList[i];
      return d == null ? true : d.h > d.w;
    }
    bool fullPageAt(int i) {
      final d = dimsList[i];
      return d != null && d.h > d.w && d.w >= _fullPageMinWidthPx;
    }

    // Index of the LAST successful photo per memory → QR placed at end of memory.
    final lastPhotoIndexByMemory = <String, int>{};
    for (int i = 0; i < successfulPhotos.length; i++) {
      lastPhotoIndexByMemory[successfulPhotos[i].memory.id] = i;
    }

    // Construit l'entrée d'une photo : titre + description seulement sur la 1ʳᵉ
    // photo du souvenir ; QR (lien d'écoute) seulement sur sa dernière photo.
    final shownMemoryIds = <String>{};
    _PhotoPageEntry entryAt(int i) {
      final e = successfulPhotos[i];
      final showCaption = shownMemoryIds.add(e.memory.id);
      final isLastOfMemory = lastPhotoIndexByMemory[e.memory.id] == i;
      final hasAudio =
          e.memory.audioUrl != null && e.memory.audioUrl!.isNotEmpty;
      final hasVideo = e.memory.videoKeys.isNotEmpty;
      final listenUrl = (isLastOfMemory && hasAudio && backendUrl.isNotEmpty)
          ? '$backendUrl/listen?m=${e.memory.id}'
          : null;
      final watchUrl = (isLastOfMemory && hasVideo && backendUrl.isNotEmpty)
          ? '$backendUrl/watch?m=${e.memory.id}'
          : null;
      return _PhotoPageEntry(
        bytes: bytesByUrl[e.url]!,
        date: _dateStr(e.memory),
        title: showCaption ? e.memory.title : null,
        caption: showCaption ? e.memory.rawContent : null,
        locationComment: showCaption ? locationComments[e.memory.id] : null,
        isPortrait: isPortraitAt(i),
        listenUrl: listenUrl,
        watchUrl: watchUrl,
        videoCount: e.memory.videoKeys.length,
      );
    }

    // Pagination : 1 portrait = 1 page pleine ; les paysages sont regroupés par
    // 2 en demi-pages. L'ordre chronologique est préservé (un portrait qui
    // s'intercale vide d'abord la paire paysage en cours).
    final photoPages = <_BookPhotoPage>[];
    final pendingLandscape = <_PhotoPageEntry>[];
    void flushLandscape() {
      if (pendingLandscape.isEmpty) return;
      photoPages.add(
          _BookPhotoPage(entries: List.of(pendingLandscape), fullPage: false));
      pendingLandscape.clear();
    }

    for (int i = 0; i < successfulPhotos.length; i++) {
      final entry = entryAt(i);
      if (fullPageAt(i)) {
        flushLandscape();
        photoPages.add(_BookPhotoPage(entries: [entry], fullPage: true));
      } else {
        pendingLandscape.add(entry);
        if (pendingLandscape.length == 2) flushLandscape();
      }
    }
    flushLandscape();

    final pdfCover = _toPdf(coverColor);
    final totalPages = 1 + photoPages.length + textOnlyMemories.length;
    // A4 full-bleed — margins handled inside each widget
    final fmt = PdfPageFormat(_a4W, _a4H, marginAll: 0);

    Future<Uint8List> buildAndSave(String? svg) async {
      final doc = pw.Document(title: notebook.title, author: 'Folio');

      // 1. Cover
      doc.addPage(pw.Page(
        pageFormat: fmt,
        build: (_) => _coverPageNotebook(
          notebook: notebook,
          svgString: svg,
          cover: pdfCover,
          pR: playfairR,
          pB: playfairB,
          coverPhotoBytes: coverPhotoBytes,
          yearRange: yearRange,
          highlights: highlights,
          customTitle: customTitle,
          customSubtitle: customSubtitle,
        ),
      ));

      // 2. Photo pages (portrait pleine page, ou 1-2 paysages par page)
      for (int p = 0; p < photoPages.length; p++) {
        final pageNum = p + 2;
        final page = photoPages[p];
        doc.addPage(pw.Page(
          pageFormat: fmt,
          build: (_) => _photoPage(
            entries: page.entries,
            fullPage: page.fullPage,
            cover: pdfCover,
            pR: playfairR,
            pB: playfairB,
            dm: dmSans,
            pageNum: pageNum,
            total: totalPages,
          ),
        ));
      }

      // 3. Text-only pages for memories without photos
      for (int t = 0; t < textOnlyMemories.length; t++) {
        final pageNum = 1 + photoPages.length + t + 1;
        doc.addPage(pw.Page(
          pageFormat: fmt,
          build: (_) => _textOnlyPage(
            memory: textOnlyMemories[t],
            cover: pdfCover,
            pR: playfairR,
            pB: playfairB,
            dm: dmSans,
            pageNum: pageNum,
            total: totalPages,
            backendUrl: backendUrl,
          ),
        ));
      }

      // 4. Pages blanches de bourrage pour atteindre un nombre de pages valide
      //    chez Gelato (pair, 28–200). Uniquement pour l'impression.
      if (padForPrint) {
        for (int p = totalPages; p < _gelatoValidPageCount(totalPages); p++) {
          doc.addPage(pw.Page(
            pageFormat: fmt,
            build: (_) => pw.Container(color: _cream),
          ));
        }
      }

      return doc.save();
    }

    final finalPageCount =
        padForPrint ? _gelatoValidPageCount(totalPages) : totalPages;
    Uint8List bytes;
    if (svgString != null) {
      try {
        bytes = await buildAndSave(svgString);
      } catch (_) {
        bytes = await buildAndSave(null);
      }
    } else {
      bytes = await buildAndSave(null);
    }
    return (bytes: bytes, pageCount: finalPageCount);
  }

  // Arrondit au nombre de pages valide Gelato le plus proche par le haut :
  // pair, minimum 28, maximum 200.
  static int _gelatoValidPageCount(int n) {
    var v = n < 28 ? 28 : (n.isOdd ? n + 1 : n);
    if (v > 200) v = 200;
    return v;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  // Largeur min (px) d'une photo portrait pour la passer en pleine page (21 cm
  // de large → ~1400 px ≈ 170 DPI). En-dessous, on la met en demi-page.
  static const int _fullPageMinWidthPx = 1400;

  // Lit (largeur, hauteur) en pixels depuis les en-têtes PNG/JPEG — sans package.
  static ({int w, int h})? _imgDims(Uint8List bytes) {
    if (bytes.length < 4) return null;
    // PNG : 89 50 4E 47 … largeur [16..19], hauteur [20..23]
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes.length >= 24) {
      final w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
      return (w: w, h: h);
    }
    // JPEG : FF D8 … marqueur SOFn
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      int i = 2;
      while (i < bytes.length - 3) {
        if (bytes[i] != 0xFF) break;
        final marker = bytes[i + 1];
        if (marker >= 0xC0 && marker <= 0xC3) {
          if (i + 9 < bytes.length) {
            final h = (bytes[i + 5] << 8) | bytes[i + 6];
            final w = (bytes[i + 7] << 8) | bytes[i + 8];
            return (w: w, h: h);
          }
        }
        if (i + 3 >= bytes.length) break;
        final len = (bytes[i + 2] << 8) | bytes[i + 3];
        if (len < 2) break;
        i += 2 + len;
      }
    }
    return null;
  }

  static List<String> _coverHighlights(List<MemoryModel> memories) {
    final result = <String>[];
    for (final m in memories) {
      if (m.type == 'taille_poids') continue;
      final t = m.title?.trim();
      if (t != null && t.isNotEmpty) {
        result.add(t);
      } else {
        final words = m.rawContent.trim().split(RegExp(r'\s+')).take(4).join(' ');
        if (words.isNotEmpty) result.add(words);
      }
      if (result.length >= 15) break;
    }
    return result;
  }

  // ── Photo page — A4 full-bleed, caption encadré au-dessus ───────────────

  static String _dateStr(MemoryModel m) =>
      m.dateLabel ??
      '${m.date.day.toString().padLeft(2, '0')}/'
          '${m.date.month.toString().padLeft(2, '0')}/'
          '${m.date.year}';

  static pw.Widget _photoPage({
    required List<_PhotoPageEntry> entries,
    required PdfColor cover,
    required pw.Font pR,
    required pw.Font pB,
    required pw.Font dm,
    required int pageNum,
    required int total,
    bool fullPage = false,
  }) {
    if (entries.isEmpty) return pw.Container();

    // Caption box (white solid — no alpha issues)
    pw.Widget captionBox(_PhotoPageEntry e, {double maxChars = 220}) {
      final hasTitle = e.title?.isNotEmpty ?? false;
      final hasBody = (e.caption?.isNotEmpty ?? false) || (e.locationComment?.isNotEmpty ?? false) || hasTitle;
      return pw.Container(
        color: PdfColors.white,
        padding: pw.EdgeInsets.fromLTRB(14, hasBody ? 10 : 7, 14, hasBody ? 10 : 7),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(e.date,
              style: pw.TextStyle(font: pR, fontSize: 8.5, color: cover, fontStyle: pw.FontStyle.italic)),
            if (hasTitle) ...[
              pw.SizedBox(height: 3),
              pw.Text(e.title!,
                style: pw.TextStyle(font: pB, fontSize: 11.5, color: _textDark, letterSpacing: 0.2)),
            ],
            if (e.caption != null && e.caption!.isNotEmpty) ...[
              pw.SizedBox(height: 4),
              pw.Text(
                e.caption!.length > maxChars.toInt()
                    ? '${e.caption!.substring(0, maxChars.toInt())}…'
                    : e.caption!,
                style: pw.TextStyle(font: dm, fontSize: 9.5, color: _textDark, lineSpacing: 2.5)),
            ],
            if (e.locationComment != null && e.locationComment!.isNotEmpty) ...[
              pw.SizedBox(height: 4),
              pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Container(
                  margin: const pw.EdgeInsets.only(top: 2.5), width: 3, height: 3,
                  decoration: pw.BoxDecoration(color: cover, shape: pw.BoxShape.circle)),
                pw.SizedBox(width: 4),
                pw.Expanded(child: pw.Text(e.locationComment!,
                  style: pw.TextStyle(font: pR, fontSize: 8, color: cover, fontStyle: pw.FontStyle.italic))),
              ]),
            ],
          ],
        ),
      );
    }

    // Page number badge (bottom-right, white bg)
    final pageBadge = pw.Container(
      color: PdfColors.white,
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: pw.Text('$pageNum / $total',
        style: pw.TextStyle(font: pR, fontSize: 7, color: _textMedium)),
    );

    // QR média (écouter / regarder) — placé au coin bas-gauche de la demi-page
    pw.Widget qrBadge(String url, String line1, String line2) => pw.Container(
      color: PdfColors.white,
      padding: const pw.EdgeInsets.fromLTRB(6, 6, 8, 6),
      child: pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
        pw.BarcodeWidget(
          barcode: pw.Barcode.qrCode(),
          data: url,
          width: 46, height: 46,
          color: _textDark,
        ),
        pw.SizedBox(width: 6),
        pw.Column(
          mainAxisSize: pw.MainAxisSize.min,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(line1, style: pw.TextStyle(font: pB, fontSize: 7.5, color: cover)),
            pw.SizedBox(height: 1),
            pw.Text(line2,
              style: pw.TextStyle(font: pR, fontSize: 6.5, color: _textMedium)),
          ],
        ),
      ]),
    );

    // Empile les QR présents (vidéo au-dessus, audio en dessous).
    int badgeCount(_PhotoPageEntry e) =>
        (e.watchUrl != null ? 1 : 0) + (e.listenUrl != null ? 1 : 0);
    pw.Widget mediaBadges(_PhotoPageEntry e) => pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (e.watchUrl != null)
          qrBadge(e.watchUrl!, 'Regarder',
              e.videoCount > 1 ? 'les vidéos' : 'la vidéo'),
        if (e.watchUrl != null && e.listenUrl != null) pw.SizedBox(height: 4),
        if (e.listenUrl != null) qrBadge(e.listenUrl!, 'Écouter', 'le mémo vocal'),
      ],
    );

    // ── Photo portrait en pleine page A4 (pas de coupe horizontale) ──
    if (fullPage) {
      final e = entries[0];
      return pw.Stack(
        children: [
          pw.SizedBox(width: _a4W, height: _a4H),
          pw.Positioned(
            left: 0, top: 0,
            child: pw.SizedBox(
              width: _a4W, height: _a4H,
              child: pw.Image(pw.MemoryImage(e.bytes),
                  fit: pw.BoxFit.cover, alignment: pw.Alignment.center),
            ),
          ),
          // Légende encadrée en haut (rentrée du fond perdu)
          pw.Positioned(top: _bleed, left: _bleed, right: _bleed,
              child: captionBox(e, maxChars: 240)),
          // QR média (vidéo / audio) en bas-gauche si présents
          if (e.listenUrl != null || e.watchUrl != null)
            pw.Positioned(bottom: _bleed, left: _bleed, child: mediaBadges(e)),
          // Numéro de page
          pw.Positioned(bottom: _bleed, right: _bleed, child: pageBadge),
        ],
      );
    }

    // Toujours demi-page : photo du haut, photo (ou fond crème) du bas
    final halfH = _a4H / 2;
    final e0 = entries[0];
    final e1 = entries.length > 1 ? entries[1] : null;

    return pw.Stack(
      children: [
        // Base — fixe la taille du Stack au format A4
        pw.SizedBox(width: _a4W, height: _a4H),

        // Demi-page haute : photo 1
        // Portrait → alignement haut (crop sur les pieds, pas sur la tête)
        pw.Positioned(left: 0, top: 0,
          child: pw.SizedBox(width: _a4W, height: halfH,
            child: pw.Image(pw.MemoryImage(e0.bytes),
              fit: pw.BoxFit.cover,
              alignment: e0.isPortrait ? pw.Alignment.topCenter : pw.Alignment.center))),

        // Demi-page basse : photo 2 ou fond crème si impair
        pw.Positioned(left: 0, top: halfH,
          child: pw.SizedBox(width: _a4W, height: halfH,
            child: e1 != null
                ? pw.Image(pw.MemoryImage(e1.bytes),
                    fit: pw.BoxFit.cover,
                    alignment: e1.isPortrait ? pw.Alignment.topCenter : pw.Alignment.center)
                : pw.Container(color: _cream))),

        // Séparateur blanc entre les deux moitiés
        pw.Positioned(left: 0, right: 0, top: halfH - 0.5,
          child: pw.Container(height: 1, color: PdfColors.white)),

        // Captions au-dessus de chaque demi-page (rentrées du fond perdu)
        pw.Positioned(top: _bleed, left: _bleed, right: _bleed,
          child: captionBox(e0, maxChars: 120)),
        if (e1 != null)
          pw.Positioned(top: halfH, left: _bleed, right: _bleed,
            child: captionBox(e1, maxChars: 120)),

        // QR média en fin de souvenir, coin bas-gauche de la demi-page.
        // La demi-page haute s'ancre juste au-dessus du séparateur (offset
        // selon le nombre de badges pour ne pas mordre sur l'image du bas).
        if (e0.listenUrl != null || e0.watchUrl != null)
          pw.Positioned(
              top: halfH - (badgeCount(e0) >= 2 ? 124 : 64),
              left: _bleed,
              child: mediaBadges(e0)),
        if (e1 != null && (e1.listenUrl != null || e1.watchUrl != null))
          pw.Positioned(bottom: _bleed, left: _bleed, child: mediaBadges(e1)),

        // Numéro de page
        pw.Positioned(bottom: _bleed, right: _bleed, child: pageBadge),
      ],
    );
  }

  static pw.Widget _coverPageNotebook({
    required NotebookModel notebook,
    required String? svgString,
    required PdfColor cover,
    required pw.Font pR,
    required pw.Font pB,
    Uint8List? coverPhotoBytes,
    required String yearRange,
    List<String> highlights = const [],
    String? customTitle,
    String? customSubtitle,
  }) {
    final displayTitle = customTitle?.isNotEmpty == true
        ? customTitle!
        : (notebook.type == 'enfant' && notebook.companionName != null
            ? '${notebook.title} & ${notebook.companionName}'
            : notebook.title);
    final displaySubtitle = customSubtitle?.isNotEmpty == true ? customSubtitle! : null;

    final highlightLine = highlights.isEmpty
        ? null
        : highlights.take(4).map((h) => '· $h').join('   ');
    // Liste exhaustive (jusqu'à 15) pour la colonne de droite de la couv. photo.
    final coverMemoList = highlights.take(15).toList();

    // "carnet" brand text — top-right on all covers
    pw.Widget folioTag() => pw.Text(
      'carnet',
      style: pw.TextStyle(
        font: pR,
        fontSize: 11,
        color: PdfColors.white,
        fontStyle: pw.FontStyle.italic,
        letterSpacing: 1.5,
      ),
    );

    // A4 dimensions in points
    const w = _a4W;
    const h = _a4H;

    if (coverPhotoBytes != null) {
      // ── Photo cover: full-bleed image + bottom title box ──
      return pw.Stack(
        children: [
          pw.SizedBox(
            width: w, height: h,
            child: pw.Image(pw.MemoryImage(coverPhotoBytes), fit: pw.BoxFit.cover),
          ),
          pw.Positioned(top: _bleed + 20, right: _bleed + 22, child: folioTag()),
          pw.Positioned(
            bottom: 0, left: 0, right: 0,
            child: pw.Container(
              color: PdfColors.white,
              // Bandeau compact (laisse plus de place à la photo) en 2 colonnes :
              // titre/sous-titre/année à gauche, liste des souvenirs à droite.
              padding: const pw.EdgeInsets.fromLTRB(24, 14, 24, 18),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      mainAxisSize: pw.MainAxisSize.min,
                      children: [
                        pw.Text(
                          displayTitle,
                          style: pw.TextStyle(font: pB, fontSize: 18, color: _textDark, letterSpacing: 0.2),
                        ),
                        if (displaySubtitle != null) ...[
                          pw.SizedBox(height: 4),
                          pw.Text(displaySubtitle,
                            style: pw.TextStyle(font: pR, fontSize: 10, color: _textMedium)),
                        ],
                        pw.SizedBox(height: 8),
                        pw.Container(width: 26, height: 1.5, color: cover),
                        pw.SizedBox(height: 8),
                        pw.Text(
                          'LIVRE DE SOUVENIRS  ·  $yearRange',
                          style: pw.TextStyle(font: pR, fontSize: 7, color: _textMedium, letterSpacing: 1.5),
                        ),
                      ],
                    ),
                  ),
                  if (coverMemoList.isNotEmpty) ...[
                    pw.SizedBox(width: 16),
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        mainAxisSize: pw.MainAxisSize.min,
                        children: coverMemoList
                            .map((h) => pw.Padding(
                                  padding: const pw.EdgeInsets.only(bottom: 1.5),
                                  child: pw.Text(
                                    '· $h',
                                    style: pw.TextStyle(font: pR, fontSize: 7, color: _textMedium),
                                    maxLines: 1,
                                    overflow: pw.TextOverflow.clip,
                                    textAlign: pw.TextAlign.right,
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    }

    // ── Solid-color cover: centered content + "folio" top-right ──
    final centeredContent = pw.Column(
      mainAxisAlignment: pw.MainAxisAlignment.center,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        if (svgString != null)
          pw.SvgImage(svg: svgString, width: 110, height: 110)
        else
          pw.Container(
            width: 72, height: 72,
            decoration: const pw.BoxDecoration(
              color: PdfColors.white,
              shape: pw.BoxShape.circle,
            ),
          ),
        pw.SizedBox(height: 26),
        pw.Text(
          displayTitle,
          style: pw.TextStyle(font: pB, fontSize: 26, color: PdfColors.white, letterSpacing: 0.4),
          textAlign: pw.TextAlign.center,
        ),
        if (displaySubtitle != null) ...[
          pw.SizedBox(height: 8),
          pw.Text(displaySubtitle,
            style: pw.TextStyle(font: pR, fontSize: 12, color: PdfColors.white),
            textAlign: pw.TextAlign.center),
        ],
        pw.SizedBox(height: 18),
        pw.Container(width: 44, height: 1.5, color: PdfColors.white),
        pw.SizedBox(height: 18),
        pw.Text(
          'LIVRE DE SOUVENIRS',
          style: pw.TextStyle(font: pR, fontSize: 8, color: PdfColors.white, letterSpacing: 3),
        ),
        pw.SizedBox(height: 6),
        pw.Text(yearRange, style: pw.TextStyle(font: pR, fontSize: 10, color: PdfColors.white)),
        if (highlightLine != null) ...[
          pw.SizedBox(height: 14),
          pw.Container(width: 40, height: 0.5, color: PdfColors.white),
          pw.SizedBox(height: 10),
          pw.Text(
            highlightLine,
            style: pw.TextStyle(font: pR, fontSize: 7.5, color: PdfColors.white, fontStyle: pw.FontStyle.italic),
            textAlign: pw.TextAlign.center,
          ),
        ],
      ],
    );

    return pw.Stack(
      children: [
        pw.SizedBox(width: w, height: h, child: pw.Container(color: cover)),
        pw.Positioned(top: _bleed + 20, right: _bleed + 22, child: folioTag()),
        pw.SizedBox(width: w, height: h, child: pw.Center(child: centeredContent)),
      ],
    );
  }

  // ── Text-only page (memories without photos) ──────────────────────────────

  static pw.Widget _textOnlyPage({
    required MemoryModel memory,
    required PdfColor cover,
    required pw.Font pR,
    required pw.Font pB,
    required pw.Font dm,
    required int pageNum,
    required int total,
    String backendUrl = '',
  }) {
    final dateStr = memory.dateLabel ??
        '${memory.date.day.toString().padLeft(2, '0')}/'
        '${memory.date.month.toString().padLeft(2, '0')}/'
        '${memory.date.year}';
    final hasAudio = memory.audioUrl != null && memory.audioUrl!.isNotEmpty;
    final listenUrl = (hasAudio && backendUrl.isNotEmpty)
        ? '$backendUrl/listen?m=${memory.id}'
        : null;
    final hasVideo = memory.videoKeys.isNotEmpty;
    final watchUrl = (hasVideo && backendUrl.isNotEmpty)
        ? '$backendUrl/watch?m=${memory.id}'
        : null;

    // QR média (texte seul) : un bloc QR + libellé, réutilisé pour vidéo/audio.
    pw.Widget mediaQr(String url, String line1, String line2) => pw.Row(children: [
      pw.BarcodeWidget(
        barcode: pw.Barcode.qrCode(),
        data: url,
        width: 56, height: 56,
        color: _textDark,
      ),
      pw.SizedBox(width: 10),
      pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(line1, style: pw.TextStyle(font: pB, fontSize: 9, color: cover)),
          pw.SizedBox(height: 2),
          pw.Text(line2, style: pw.TextStyle(font: pR, fontSize: 7.5, color: _textMedium)),
        ],
      ),
    ]);

    return pw.Container(
      color: _cream,
      padding: const pw.EdgeInsets.fromLTRB(40, 48, 40, 28),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            dateStr,
            style: pw.TextStyle(font: pR, fontSize: 9, color: cover, fontStyle: pw.FontStyle.italic, letterSpacing: 0.5),
          ),
          pw.SizedBox(height: 10),
          if (memory.title != null && memory.title!.isNotEmpty) ...[
            pw.Text(
              memory.title!,
              style: pw.TextStyle(font: pB, fontSize: 16, color: _textDark, letterSpacing: 0.2),
            ),
            pw.SizedBox(height: 10),
          ],
          pw.Container(width: 28, height: 1.5, color: cover),
          pw.SizedBox(height: 16),
          pw.Expanded(
            child: pw.Text(
              memory.rawContent,
              style: pw.TextStyle(font: pR, fontSize: 11, color: _textDark, lineSpacing: 5),
            ),
          ),
          if (memory.location != null && memory.location!.isNotEmpty) ...[
            pw.SizedBox(height: 8),
            pw.Row(children: [
              pw.Container(width: 3, height: 3, margin: const pw.EdgeInsets.only(top: 2),
                decoration: pw.BoxDecoration(color: cover, shape: pw.BoxShape.circle)),
              pw.SizedBox(width: 5),
              pw.Text(memory.location!,
                style: pw.TextStyle(font: pR, fontSize: 8, color: cover, fontStyle: pw.FontStyle.italic)),
            ]),
          ],
          if (watchUrl != null) ...[
            pw.SizedBox(height: 16),
            mediaQr(
                watchUrl,
                memory.videoKeys.length > 1
                    ? 'Regarder les vidéos'
                    : 'Regarder la vidéo',
                memory.videoKeys.length > 1
                    ? 'Scanne ce code pour voir les vidéos.'
                    : 'Scanne ce code pour voir la vidéo.'),
          ],
          if (listenUrl != null) ...[
            pw.SizedBox(height: 16),
            mediaQr(listenUrl, 'Écouter le mémo vocal',
                'Scanne ce code pour écouter le message.'),
          ],
          pw.SizedBox(height: 8),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text('$pageNum / $total',
              style: pw.TextStyle(font: dm, fontSize: 8, color: _textMedium)),
          ),
        ],
      ),
    );
  }

  // ── Cover (legacy ChildModel) ──────────────────────────────────────────────

  static pw.Widget _coverPage({
    required ChildModel child,
    required String? svgString,
    required PdfColor cover,
    required pw.Font pR,
    required pw.Font pB,
  }) {
    final birth = child.birthDate;
    final nowYear = DateTime.now().year;
    final range =
        birth.year == nowYear ? '${birth.year}' : '${birth.year} — $nowYear';

    return pw.Container(
      decoration: pw.BoxDecoration(color: cover),
      child: pw.Center(
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            if (svgString != null)
              pw.SvgImage(svg: svgString, width: 120, height: 120)
            else
              pw.Container(
                width: 80,
                height: 80,
                decoration: const pw.BoxDecoration(
                  color: PdfColors.white,
                  shape: pw.BoxShape.circle,
                ),
              ),
            pw.SizedBox(height: 24),
            pw.Text(
              'Le livre de',
              style: pw.TextStyle(
                font: pR,
                fontSize: 13,
                color: PdfColors.white,
                fontStyle: pw.FontStyle.italic,
                letterSpacing: 1.5,
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              child.firstName,
              style: pw.TextStyle(
                font: pB,
                fontSize: 34,
                color: PdfColors.white,
              ),
            ),
            pw.SizedBox(height: 20),
            pw.Container(width: 48, height: 1.5, color: PdfColors.white),
            pw.SizedBox(height: 20),
            pw.Text(
              'LIVRE DE SOUVENIRS',
              style: pw.TextStyle(
                font: pR,
                fontSize: 8,
                color: PdfColors.white,
                letterSpacing: 3,
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              range,
              style:
                  pw.TextStyle(font: pR, fontSize: 10, color: PdfColors.white),
            ),
          ],
        ),
      ),
    );
  }

  // ── Chapter ────────────────────────────────────────────────────────────────

  static pw.Widget _chapterPage({
    required BookChapter chapter,
    required int idx,
    required PdfColor cover,
    required pw.Font pR,
    required pw.Font pB,
    required pw.Font dm,
    required int pageNum,
    required int total,
    required List<String> roman,
  }) {
    return pw.Container(
      color: _cream,
      padding: const pw.EdgeInsets.fromLTRB(36, 40, 36, 24),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            'Chapitre ${roman[idx % roman.length]}',
            style: pw.TextStyle(
              font: pR,
              fontSize: 9,
              letterSpacing: 3,
              color: cover,
            ),
          ),
          pw.SizedBox(height: 10),
          if (chapter.title.isNotEmpty)
            pw.Text(
              chapter.title,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(font: pB, fontSize: 17, color: _textDark),
            ),
          pw.SizedBox(height: 14),
          // Ornamental divider
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.Container(width: 22, height: 1, color: cover),
              pw.SizedBox(width: 6),
              pw.Container(
                width: 5,
                height: 5,
                decoration:
                    pw.BoxDecoration(color: cover, shape: pw.BoxShape.circle),
              ),
              pw.SizedBox(width: 6),
              pw.Container(width: 22, height: 1, color: cover),
            ],
          ),
          pw.SizedBox(height: 20),
          pw.Expanded(
            child: pw.Text(
              chapter.body,
              textAlign: pw.TextAlign.justify,
              style: pw.TextStyle(
                font: pR,
                fontSize: 11,
                color: _textDark,
                lineSpacing: 5.5,
              ),
            ),
          ),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              '$pageNum / $total',
              style: pw.TextStyle(font: dm, fontSize: 8, color: _textMedium),
            ),
          ),
        ],
      ),
    );
  }

  // ── Growth page ────────────────────────────────────────────────────────────

  static pw.Widget _growthPage({
    required ChildModel child,
    required List<MilestoneModel> milestones,
    required PdfColor cover,
    required Color coverFlutter,
    required pw.Font pB,
    required pw.Font dm,
    required int pageNum,
    required int total,
  }) {
    final heights = milestones.where((m) => m.heightCm != null).toList();
    final weights = milestones.where((m) => m.weightKg != null).toList();

    return pw.Container(
      color: _cream,
      padding: const pw.EdgeInsets.fromLTRB(28, 28, 28, 20),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Title
          pw.Row(
            children: [
              pw.Container(width: 3, height: 18, color: cover),
              pw.SizedBox(width: 10),
              pw.Text(
                'Évolution croissance',
                style: pw.TextStyle(font: pB, fontSize: 15, color: _textDark),
              ),
            ],
          ),
          pw.SizedBox(height: 3),
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 13),
            child: pw.Text(
              'Source : OMS 2006 — Courbes de référence P3, P50, P97',
              style: pw.TextStyle(font: dm, fontSize: 7, color: _textMedium),
            ),
          ),
          pw.SizedBox(height: 18),

          // Two columns: height + weight
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (heights.isNotEmpty)
                pw.Expanded(
                  child: _measureColumn(
                    label: 'Taille (cm)',
                    measures: heights,
                    getValue: (m) => m.heightCm!,
                    formatVal: (v) => '${v.toStringAsFixed(0)} cm',
                    cover: cover,
                    coverFlutter: coverFlutter,
                    child: child,
                    pB: pB,
                    dm: dm,
                  ),
                ),
              if (heights.isNotEmpty && weights.isNotEmpty)
                pw.SizedBox(width: 14),
              if (weights.isNotEmpty)
                pw.Expanded(
                  child: _measureColumn(
                    label: 'Poids (kg)',
                    measures: weights,
                    getValue: (m) => m.weightKg!,
                    formatVal: (v) => '${v.toStringAsFixed(1)} kg',
                    cover: cover,
                    coverFlutter: coverFlutter,
                    child: child,
                    pB: pB,
                    dm: dm,
                  ),
                ),
            ],
          ),

          pw.Spacer(),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              '$pageNum / $total',
              style: pw.TextStyle(font: dm, fontSize: 8, color: _textMedium),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _measureColumn({
    required String label,
    required List<MilestoneModel> measures,
    required double Function(MilestoneModel) getValue,
    required String Function(double) formatVal,
    required PdfColor cover,
    required Color coverFlutter,
    required ChildModel child,
    required pw.Font pB,
    required pw.Font dm,
  }) {
    final values = measures.map(getValue).toList();
    final minVal = values.reduce(min);
    final maxVal = values.reduce(max);
    final range = maxVal - minVal;

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label,
            style: pw.TextStyle(font: pB, fontSize: 10, color: _textDark)),
        pw.SizedBox(height: 8),

        // Bar chart
        pw.SizedBox(
          height: 64,
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: measures.asMap().entries.map((e) {
              final i = e.key;
              final val = getValue(e.value);
              final normalized = range > 0 ? (val - minVal) / range : 1.0;
              final barH = 10.0 + normalized * 54.0;
              final isLatest = i == measures.length - 1;
              return pw.Expanded(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 1),
                  child: pw.Container(
                    height: barH,
                    color: isLatest
                        ? cover
                        : _toPdfWithAlpha(
                            coverFlutter, 0.25 + normalized * 0.45),
                  ),
                ),
              );
            }).toList(),
          ),
        ),

        pw.SizedBox(height: 10),

        // Measurements list
        ...measures.reversed.take(6).map((m) {
          final isLatest = m == measures.last;
          final date = m.dateLabel ??
              formatDateWithPrecision(
                  m.date, datePrecisionFromString(m.datePrecision));
          return pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: pw.Row(
              children: [
                pw.Container(
                  width: 5,
                  height: 5,
                  decoration: pw.BoxDecoration(
                    color: isLatest ? cover : _textMedium,
                    shape: pw.BoxShape.circle,
                  ),
                ),
                pw.SizedBox(width: 5),
                pw.Expanded(
                  child: pw.Text(
                    date,
                    style: pw.TextStyle(
                        font: dm, fontSize: 7.5, color: _textMedium),
                  ),
                ),
                pw.Text(
                  formatVal(getValue(m)),
                  style: pw.TextStyle(
                    font: pB,
                    fontSize: 8.5,
                    color: isLatest ? cover : _textDark,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _PhotoEntry {
  final MemoryModel memory;
  final String url;
  const _PhotoEntry({required this.memory, required this.url});
}

/// Une page de photos : soit un portrait en pleine page (`fullPage`), soit
/// 1 à 2 photos paysage en demi-pages.
class _BookPhotoPage {
  final List<_PhotoPageEntry> entries;
  final bool fullPage;
  const _BookPhotoPage({required this.entries, required this.fullPage});
}

class _PhotoPageEntry {
  final Uint8List bytes;
  final String date;
  final String? title;
  final String? caption;
  final String? locationComment;
  final bool isPortrait;
  final String? listenUrl;
  final String? watchUrl;
  final int videoCount;
  const _PhotoPageEntry({required this.bytes, required this.date, this.title, this.caption, this.locationComment, this.isPortrait = true, this.listenUrl, this.watchUrl, this.videoCount = 0});
}
