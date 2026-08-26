import 'dart:math' show max, min;

import 'package:barcode/barcode.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// QR code « cœur » : un QR code standard, mais dont les trois repères de
/// position (les gros carrés des coins) portent le cœur du logo Carnet à la
/// place de leur pavé central.
///
/// Réservé aux QR de SOUVENIR — le QR de couverture (toutes les vidéos du
/// livre) et les QR vidéo/mémo vocal posés dans les pages. Les autres QR du
/// produit restent des QR nus.
///
/// Ce qui change est strictement décoratif du point de vue d'un scanner :
///  - aucun module de données ne bouge ;
///  - l'anneau des repères garde EXACTEMENT le gabarit de la norme (7×7,
///    anneau d'un module, blanc d'un module) ; seul le pavé central 3×3
///    devient un cœur, d'encombrement 3,4 × 3,4 modules.
///
/// Ces deux cotes ne sont pas décoratives : mesurées sur 40 « photos »
/// simulées par taille (perspective, flou, bruit) avec le détecteur QR
/// d'OpenCV, un cœur de 3,4 × 3,4 se lit aussi bien qu'un repère nu (≥ 97 %
/// partout où le code nu passe), alors que des coins d'anneau arrondis —
/// pourtant plus proches de la maquette — font chuter la lecture dès le
/// premier dixième de module d'arrondi. On garde donc l'anneau au carré.
class HeartQr {
  /// Cœur du logo (assets/branding/svg/carnet-mark.svg), dans les coordonnées
  /// du SVG d'origine : x ∈ [110, 402], y ∈ [128, 358], y vers le BAS.
  static const double _svgMinX = 110;
  static const double _svgMaxX = 402;
  static const double _svgMinY = 128;
  static const double _svgMaxY = 358;

  /// Encombrement du cœur, en modules, dans le pavé central 3×3 du repère.
  /// Un peu plus grand que le pavé d'origine (le cœur est creusé en haut et
  /// pointu en bas : à 3×3 pile, les lignes de balayage passant par le centre
  /// verraient un pavé trop court). Reste à 0,8 module de l'anneau.
  static const double _heartW = 3.4;
  static const double _heartH = 3.4;

  /// Marge blanche autour du code, en modules. La norme en demande 4 ; on en
  /// pose 2 ici parce que ces QR sont toujours posés sur un fond blanc franc
  /// (bandeau de couverture, cartouche des pages) qui fournit le reste.
  static const double _quietZone = 2;

  /// [size] = côté du carré rendu (marge blanche comprise).
  ///
  /// Si la matrice du QR ne peut pas être lue (données trop longues pour un
  /// QR, version du paquet inattendue…), on retombe sur un QR nu de la même
  /// taille : mieux vaut un code sans cœur qu'une couverture sans code.
  static pw.Widget build({
    required String data,
    required double size,
    required PdfColor color,
    PdfColor? background,
  }) {
    final matrix = _matrix(data);
    if (matrix == null) {
      return pw.BarcodeWidget(
        barcode: pw.Barcode.qrCode(),
        data: data,
        width: size,
        height: size,
        color: color,
      );
    }

    final n = matrix.size;
    final cells = matrix.cells;
    final module = size / (n + 2 * _quietZone);
    final origin = module * _quietZone;

    // Coin bas-gauche (repère PDF : y vers le HAUT) de la case (row, col).
    double left(int col) => origin + col * module;
    double bottom(int row) => size - origin - (row + 1) * module;

    return pw.SizedBox(
      width: size,
      height: size,
      child: pw.CustomPaint(
        size: PdfPoint(size, size),
        painter: (PdfGraphics canvas, PdfPoint _) {
          if (background != null) {
            canvas
              ..setFillColor(background)
              ..drawRect(0, 0, size, size)
              ..fillPath();
          }

          canvas.setFillColor(color);

          // 1. Modules de données — inchangés, un carré plein par module.
          for (final cell in cells) {
            if (_isFinder(n, cell.row, cell.col)) continue;
            canvas.drawRect(left(cell.col), bottom(cell.row), module, module);
          }
          canvas.fillPath();

          // 2. Les trois repères de position, revisités.
          for (final finder in [[0, 0], [0, n - 7], [n - 7, 0]]) {
            _drawFinder(
              canvas,
              x: left(finder[1]),
              y: bottom(finder[0] + 6),
              module: module,
            );
          }
        },
      ),
    );
  }

  /// Anneau 7×7 de la norme + cœur à la place du pavé central.
  /// [x], [y] = coin bas-gauche du repère.
  static void _drawFinder(
    PdfGraphics canvas, {
    required double x,
    required double y,
    required double module,
  }) {
    // Anneau : carré extérieur 7×7 moins carré intérieur 5×5, rempli en
    // « even-odd » — le trou reste transparent (pas de blanc peint par-dessus,
    // le QR peut donc être posé sur n'importe quel fond clair).
    canvas
      ..drawRect(x, y, module * 7, module * 7)
      ..drawRect(x + module, y + module, module * 5, module * 5)
      ..fillPath(evenOdd: true);

    final w = module * _heartW;
    final h = module * _heartH;
    _heartPath(
      canvas,
      x: x + module * 3.5 - w / 2,
      y: y + module * 3.5 - h / 2,
      w: w,
      h: h,
    );
    canvas.fillPath();
  }

  /// Trace le cœur du logo dans la boîte ([x], [y], [w], [h]).
  static void _heartPath(
    PdfGraphics canvas, {
    required double x,
    required double y,
    required double w,
    required double h,
  }) {
    double px(double sx) => x + (sx - _svgMinX) / (_svgMaxX - _svgMinX) * w;
    double py(double sy) => y + h - (sy - _svgMinY) / (_svgMaxY - _svgMinY) * h;

    canvas
      ..moveTo(px(256), py(180))
      ..curveTo(px(240), py(150), px(214), py(128), px(180), py(128))
      ..curveTo(px(145), py(128), px(110), py(150), px(110), py(192))
      ..curveTo(px(110), py(240), px(150), py(290), px(256), py(358))
      ..curveTo(px(362), py(290), px(402), py(240), px(402), py(192))
      ..curveTo(px(402), py(150), px(367), py(128), px(332), py(128))
      ..curveTo(px(298), py(128), px(272), py(150), px(256), py(180))
      ..closePath();
  }

  /// Vrai si la case appartient à l'un des trois repères de position (qu'on
  /// redessine nous-mêmes) plutôt qu'aux données.
  static bool _isFinder(int n, int row, int col) =>
      (row < 7 && col < 7) ||
      (row < 7 && col >= n - 7) ||
      (row >= n - 7 && col < 7);

  /// Matrice du QR, récupérée en faisant rendre le code dans un carré de côté
  /// 1 : chaque module noir revient comme une barre dont la taille donne le
  /// nombre de modules du code.
  static _QrMatrix? _matrix(String data) {
    try {
      final bars = Barcode.qrCode()
          .make(data, width: 1, height: 1)
          .whereType<BarcodeBar>()
          .where((b) => b.black)
          .toList();
      if (bars.isEmpty) return null;
      // Le module = la plus petite barre rendue. Passer par le minimum (et
      // non par la première barre) laisse la porte ouverte à une version du
      // paquet qui fusionnerait les modules noirs voisins en une seule barre.
      var module = double.infinity;
      for (final b in bars) {
        module = min(module, min(b.width, b.height));
      }
      if (module <= 0 || !module.isFinite) return null;

      final cells = <_QrCell>[];
      for (final b in bars) {
        final col = (b.left / module).round();
        final row = (b.top / module).round();
        final cols = (b.width / module).round();
        final rows = (b.height / module).round();
        for (var dr = 0; dr < rows; dr++) {
          for (var dc = 0; dc < cols; dc++) {
            cells.add(_QrCell(row + dr, col + dc));
          }
        }
      }

      // Le côté du code se déduit de l'étendue des modules noirs plutôt que de
      // 1/module : les trois repères de position touchent forcément les quatre
      // bords utiles, donc l'étendue EST le code — même si le paquet décidait
      // un jour d'ajouter lui-même une marge blanche autour.
      var minRow = cells.first.row, maxRow = cells.first.row;
      var minCol = cells.first.col, maxCol = cells.first.col;
      for (final c in cells) {
        minRow = min(minRow, c.row);
        maxRow = max(maxRow, c.row);
        minCol = min(minCol, c.col);
        maxCol = max(maxCol, c.col);
      }
      final n = max(maxRow - minRow, maxCol - minCol) + 1;
      // Tailles possibles d'un QR : 21, 25, … 177 (version 1 à 40). Tout le
      // reste veut dire qu'on n'a pas lu ce qu'on croyait — on rend la main au
      // QR nu plutôt que de dessiner des cœurs au petit bonheur.
      if (n < 21 || n > 177 || n % 4 != 1) return null;

      return _QrMatrix(
        n,
        [
          for (final c in cells) _QrCell(c.row - minRow, c.col - minCol),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

class _QrMatrix {
  const _QrMatrix(this.size, this.cells);
  final int size;
  final List<_QrCell> cells;
}

class _QrCell {
  const _QrCell(this.row, this.col);
  final int row;
  final int col;
}
