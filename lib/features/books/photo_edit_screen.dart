import 'package:flutter/material.dart';
import '../../core/models/book_draft.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/theme/app_theme.dart';

/// Ce que l'utilisateur a décidé pour une photo touchée dans l'éditeur
/// d'aperçu du livre.
sealed class PhotoEditResult {
  const PhotoEditResult();
}

/// Texte enregistré (null = texte supprimé).
class PhotoTextSaved extends PhotoEditResult {
  final BookPhotoText? text;
  const PhotoTextSaved(this.text);
}

class PhotoRemoved extends PhotoEditResult {
  const PhotoRemoved();
}

class PhotoFeaturedToggled extends PhotoEditResult {
  const PhotoFeaturedToggled();
}

/// Écran « cette photo », plein écran : la photo telle qu'elle sera IMPRIMÉE
/// (même recadrage, même géométrie que la case du PDF), et son commentaire
/// dans un encadré qu'on déplace au doigt — police, taille, couleur, encadré.
///
/// Tout est rendu à l'échelle de la case du PDF (`slot.widthPt/heightPt`), si
/// bien que ce qui est à l'écran est ce qui sort de l'imprimeur : les mêmes
/// .ttf, la même taille relative, la même zone de sécurité.
///
/// Une pression sur la photo masque les réglages — on voit alors la photo en
/// entier, sans rien par-dessus.
class PhotoEditScreen extends StatefulWidget {
  final BookPhotoText? initial;
  final bool featured;
  final BookPhotoSlot slot;

  /// Réglages proposés pour un NOUVEAU texte : les derniers choisis.
  final String defaultColor;
  final String defaultFont;
  final double defaultScale;

  const PhotoEditScreen({
    super.key,
    required this.slot,
    required this.defaultColor,
    this.defaultFont = BookPhotoText.fontSerif,
    this.defaultScale = 1,
    this.initial,
    this.featured = false,
  });

  static Future<PhotoEditResult?> open(
    BuildContext context, {
    required BookPhotoSlot slot,
    required String defaultColor,
    String defaultFont = BookPhotoText.fontSerif,
    double defaultScale = 1,
    BookPhotoText? initial,
    bool featured = false,
  }) =>
      Navigator.of(context).push<PhotoEditResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => PhotoEditScreen(
            slot: slot,
            defaultColor: defaultColor,
            defaultFont: defaultFont,
            defaultScale: defaultScale,
            initial: initial,
            featured: featured,
          ),
        ),
      );

  @override
  State<PhotoEditScreen> createState() => _PhotoEditScreenState();
}

class _PhotoEditScreenState extends State<PhotoEditScreen> {
  late final TextEditingController _textCtrl;
  late String _color;
  late String _font;
  late double _scale;
  late bool _background;
  late double _x;
  late double _y;
  final _boxKey = GlobalKey();

  /// Réglages visibles. Masqués = la photo occupe tout l'écran.
  bool _tools = true;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _textCtrl = TextEditingController(text: t?.text ?? '');
    _color = t?.color ?? widget.defaultColor;
    _font = BookPhotoText.normalizeFont(t?.font ?? widget.defaultFont);
    _scale = BookPhotoText.normalizeScale(t?.scale ?? widget.defaultScale);
    _background = t?.background ?? true;
    // Ancien texte sans position libre : on le place là où il était.
    _x = t?.x ?? BookPhotoText.defaultX;
    _y = t?.y ??
        (t?.position == 'top'
            ? 1 - BookPhotoText.defaultY
            : BookPhotoText.defaultY);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  static Color _hex(String hex) =>
      Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));

  BookPhotoText? get _current {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return null;
    return BookPhotoText(
      text: text,
      color: _color,
      background: _background,
      x: _x,
      y: _y,
      font: _font,
      scale: _scale,
    );
  }

  void _save() => Navigator.pop(context, PhotoTextSaved(_current));

  /// Recadrage : exactement celui du PDF (BookPdfService._cropAlignment).
  Alignment get _cropAlignment {
    final f = widget.slot.focus;
    if (f != null) return Alignment(f.alignX, f.alignY);
    return widget.slot.isPortrait ? Alignment.topCenter : Alignment.center;
  }

  /// La photo cadrée comme dans le livre, et l'encadré déplaçable par-dessus.
  Widget _photo(BoxConstraints box) {
    final slot = widget.slot;
    final cellW = slot.widthPt > 0 ? slot.widthPt : 1.0;
    final cellH = slot.heightPt > 0 ? slot.heightPt : 1.0;
    var w = box.maxWidth;
    var h = w * cellH / cellW;
    if (h > box.maxHeight) {
      h = box.maxHeight;
      w = h * cellW / cellH;
    }
    // Échelle points PDF → pixels écran : même mise en page que le PDF.
    final scale = w / cellW;
    final inset = BookPdfService.safeMarginPt * scale;
    final areaW = w - 2 * inset, areaH = h - 2 * inset;
    final text = _textCtrl.text.trim();

    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  // Toucher la photo (hors encadré) = voir la photo seule.
                  onTap: () => setState(() => _tools = !_tools),
                  child: slot.bytes != null
                      ? Image.memory(slot.bytes!,
                          fit: BoxFit.cover, alignment: _cropAlignment)
                      : Container(color: AppColors.softGray),
                ),
              ),
              if (areaW > 0 && areaH > 0)
                Positioned(
                  left: inset,
                  top: inset,
                  width: areaW,
                  height: areaH,
                  child: Align(
                    alignment: Alignment(_x * 2 - 1, _y * 2 - 1),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: areaW * BookPdfService.photoTextMaxWidth),
                      child: GestureDetector(
                        onPanUpdate: (d) {
                          final size = _boxKey.currentContext?.size;
                          if (size == null) return;
                          final rangeX = areaW - size.width;
                          final rangeY = areaH - size.height;
                          setState(() {
                            if (rangeX > 0) {
                              _x = (_x + d.delta.dx / rangeX).clamp(0.0, 1.0);
                            }
                            if (rangeY > 0) {
                              _y = (_y + d.delta.dy / rangeY).clamp(0.0, 1.0);
                            }
                          });
                        },
                        child: _textBox(scale, text, areaH / scale),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// L'encadré du texte, rendu avec les mêmes valeurs que le PDF
  /// (BookPdfService._photoTextLabel), mises à l'échelle de l'écran.
  Widget _textBox(double scale, String text, double availableHeightPt) {
    final color = _hex(_color);
    final bg = color.computeLuminance() > 0.8 ? AppColors.ink : Colors.white;
    // Un texte vide n'existe pas encore dans le livre : on le montre quand
    // même (en plus pâle) pour pouvoir le placer avant d'écrire.
    final preview = text.isEmpty ? 'Ton commentaire' : text;
    final sample =
        BookPhotoText(text: preview, color: _color, font: _font, scale: _scale);

    return Container(
      key: _boxKey,
      padding: _background
          ? EdgeInsets.symmetric(
              horizontal:
                  BookPdfService.photoTextPadH * sample.padFactor * scale,
              vertical: BookPdfService.photoTextPadV * sample.padFactor * scale)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: _background ? bg : null,
        border: Border.all(
            color: _tools ? AppColors.sageDark : Colors.transparent,
            width: _tools ? 1.5 : 0),
      ),
      child: Text(
        preview,
        textAlign: TextAlign.center,
        maxLines: sample.lineCapacity(
            availableHeight: availableHeightPt,
            baseFontSize: BookPdfService.photoTextFontSize,
            basePadV: BookPdfService.photoTextPadV),
        style: TextStyle(
          fontFamily: BookPhotoText.familyOf(_font),
          fontSize:
              BookPdfService.photoTextFontSize * sample.sizeFactor * scale,
          height: 1.25,
          color: text.isEmpty ? color.withOpacity(0.45) : color,
        ),
      ),
    );
  }

  // ── Réglages ──────────────────────────────────────────────────────────────

  Widget _fontPicker() => Row(
        children: [
          for (final f in BookPhotoText.fonts)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _font = f),
                  child: Container(
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: f == _font
                          ? AppColors.sageDark.withOpacity(0.25)
                          : Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: f == _font
                            ? AppColors.sageDark
                            : Colors.white.withOpacity(0.15),
                        width: f == _font ? 2 : 1,
                      ),
                    ),
                    child: Text(
                      BookPhotoText.labelOf(f),
                      style: TextStyle(
                        fontFamily: BookPhotoText.familyOf(f),
                        color: Colors.white,
                        fontSize:
                            15 * BookPhotoText.metricOf(f).clamp(1.0, 1.2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );

  Widget _sizePicker() => Row(
        children: [
          const Icon(Icons.text_decrease, color: Colors.white54, size: 20),
          Expanded(
            child: Slider(
              value: _scale,
              min: BookPhotoText.minScale,
              max: BookPhotoText.maxScale,
              // Crans discrets : on retombe toujours sur une taille ronde,
              // donc reproductible d'une photo à l'autre.
              divisions: 15,
              activeColor: AppColors.sageDark,
              inactiveColor: Colors.white24,
              label: '${(_scale * 100).round()} %',
              onChanged: (v) => setState(() => _scale = v),
            ),
          ),
          const Icon(Icons.text_increase, color: Colors.white54, size: 22),
        ],
      );

  Widget _colorPicker() => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final hex in BookPhotoText.palette)
            GestureDetector(
              onTap: () => setState(() => _color = hex),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _hex(hex),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: hex == _color ? AppColors.sageDark : Colors.white24,
                    width: hex == _color ? 3 : 1,
                  ),
                ),
              ),
            ),
        ],
      );

  Widget _tool({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white70,
  }) =>
      TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18, color: color),
        label: Text(label, style: TextStyle(fontSize: 12.5, color: color)),
        style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8)),
      );

  Widget _panel() => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        // Jamais plus de la moitié de l'écran, et défilable : sur un petit
        // téléphone, clavier ouvert, la photo garde de la place et les
        // réglages restent tous atteignables.
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.52),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _textCtrl,
                autofocus: widget.initial == null,
                maxLength: BookPhotoText.maxLength,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                cursorColor: AppColors.sageDark,
                decoration: InputDecoration(
                  hintText: 'Ton commentaire sur cette photo…',
                  hintStyle: const TextStyle(color: Colors.white38),
                  counterStyle:
                      const TextStyle(color: Colors.white38, fontSize: 10),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.08),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                onChanged: (_) => setState(() {}),
              ),
              _fontPicker(),
              _sizePicker(),
              _colorPicker(),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _tool(
                    icon: _background
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    label: 'Encadré',
                    color: _background ? AppColors.sageDark : Colors.white70,
                    onTap: () => setState(() => _background = !_background),
                  ),
                  _tool(
                    icon: widget.featured
                        ? Icons.grid_view_rounded
                        : Icons.fullscreen,
                    label: widget.featured ? 'En petit' : 'En grand',
                    onTap: () =>
                        Navigator.pop(context, const PhotoFeaturedToggled()),
                  ),
                  _tool(
                    icon: Icons.delete_outline,
                    label: 'Retirer',
                    color: AppColors.error,
                    onTap: () => Navigator.pop(context, const PhotoRemoved()),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                child: Text(widget.initial != null && _current == null
                    ? 'Supprimer le commentaire'
                    : 'Enregistrer'),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Fermer sans enregistrer',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Cette photo', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: Icon(_tools ? Icons.visibility : Icons.visibility_off),
            tooltip: _tools ? 'Voir la photo seule' : 'Afficher les réglages',
            onPressed: () => setState(() => _tools = !_tools),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: LayoutBuilder(builder: (_, box) => _photo(box)),
              ),
            ),
            if (_tools)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Fais glisser l\'encadré sur la photo · appuie sur la photo '
                  'pour la voir seule',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.55), fontSize: 11.5),
                ),
              ),
            if (_tools) _panel(),
          ],
        ),
      ),
    );
  }
}
