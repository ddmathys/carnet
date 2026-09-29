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

/// Feuille « cette photo » : la photo telle qu'elle est cadrée dans le livre,
/// avec le texte dans un encadré qu'on déplace au doigt (rendu identique au
/// PDF, à l'échelle de l'écran) ; couleur, encadré blanc on/off ; mise en
/// grand ; retrait du livre.
class PhotoEditSheet extends StatefulWidget {
  final BookPhotoText? initial;
  final bool featured;
  final BookPhotoSlot slot;

  /// Couleur proposée pour un nouveau texte : la dernière choisie.
  final String defaultColor;

  const PhotoEditSheet({
    super.key,
    required this.slot,
    required this.defaultColor,
    this.initial,
    this.featured = false,
  });

  static Future<PhotoEditResult?> open(
    BuildContext context, {
    required BookPhotoSlot slot,
    required String defaultColor,
    BookPhotoText? initial,
    bool featured = false,
  }) =>
      showModalBottomSheet<PhotoEditResult>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => PhotoEditSheet(
          slot: slot,
          defaultColor: defaultColor,
          initial: initial,
          featured: featured,
        ),
      );

  @override
  State<PhotoEditSheet> createState() => _PhotoEditSheetState();
}

class _PhotoEditSheetState extends State<PhotoEditSheet> {
  late final TextEditingController _textCtrl;
  late String _color;
  late bool _background;
  late double _x;
  late double _y;
  final _boxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _textCtrl = TextEditingController(text: t?.text ?? '');
    _color = t?.color ?? widget.defaultColor;
    _background = t?.background ?? true;
    // Ancien texte sans position libre : on le place là où il était.
    _x = t?.x ?? BookPhotoText.defaultX;
    _y = t?.y ??
        (t?.position == 'top' ? 1 - BookPhotoText.defaultY : BookPhotoText.defaultY);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  static Color _hex(String hex) =>
      Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));

  void _save() {
    final text = _textCtrl.text.trim();
    Navigator.pop(
      context,
      PhotoTextSaved(text.isEmpty
          ? null
          : BookPhotoText(
              text: text,
              color: _color,
              background: _background,
              x: _x,
              y: _y,
            )),
    );
  }

  /// La photo cadrée comme dans le livre, et l'encadré déplaçable par-dessus.
  Widget _photoPreview(double maxW) {
    final slot = widget.slot;
    final cellW = slot.widthPt > 0 ? slot.widthPt : 1.0;
    final cellH = slot.heightPt > 0 ? slot.heightPt : 1.0;
    const maxH = 300.0;
    var w = maxW, h = maxW * cellH / cellW;
    if (h > maxH) {
      h = maxH;
      w = maxH * cellW / cellH;
    }
    // Échelle points PDF → pixels écran : même mise en page que le PDF.
    final scale = w / cellW;
    final inset = BookPdfService.safeMarginPt * scale;
    final areaW = w - 2 * inset, areaH = h - 2 * inset;

    final color = _hex(_color);
    final bg = color.computeLuminance() > 0.8 ? AppColors.ink : Colors.white;
    final text = _textCtrl.text.trim();

    final box = Container(
      key: _boxKey,
      padding: _background
          ? EdgeInsets.symmetric(
              horizontal: BookPdfService.photoTextPadH * scale,
              vertical: BookPdfService.photoTextPadV * scale)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: _background ? bg : null,
        border: Border.all(color: AppColors.sageDark, width: 1.5),
      ),
      child: Text(
        text.isEmpty ? 'Ton texte' : text,
        textAlign: TextAlign.center,
        maxLines: 4,
        style: TextStyle(
          fontFamily: 'PlayfairDisplay',
          fontSize: BookPdfService.photoTextFontSize * scale,
          height: 1.25,
          color: text.isEmpty ? color.withOpacity(0.45) : color,
        ),
      ),
    );

    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            children: [
              Positioned.fill(
                child: slot.bytes != null
                    ? Image.memory(slot.bytes!,
                        fit: BoxFit.cover,
                        alignment: slot.isPortrait
                            ? Alignment.topCenter
                            : Alignment.center)
                    : Container(color: AppColors.softGray),
              ),
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
                      child: box,
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

  @override
  Widget build(BuildContext context) {
    final hasInitial = widget.initial != null;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.softGray.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                  builder: (_, box) => _photoPreview(box.maxWidth)),
              const SizedBox(height: 6),
              const Text(
                'Fais glisser l\'encadré pour placer ton texte.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.softGray, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _textCtrl,
                autofocus: !hasInitial,
                maxLength: BookPhotoText.maxLength,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: AppColors.textDark),
                decoration: InputDecoration(
                  hintText: 'Ex. Premier bain de mer 🌊',
                  filled: true,
                  fillColor: AppColors.cream,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              Row(
                children: [
                  for (final hex in BookPhotoText.palette)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: GestureDetector(
                        onTap: () => setState(() => _color = hex),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: _hex(hex),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: hex == _color
                                  ? AppColors.sageDark
                                  : AppColors.border,
                              width: hex == _color ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _background,
                onChanged: (v) => setState(() => _background = v),
                title: const Text('Encadré blanc',
                    style: TextStyle(color: AppColors.textDark, fontSize: 14)),
                subtitle: const Text('Plus lisible une fois imprimé',
                    style:
                        TextStyle(color: AppColors.textMedium, fontSize: 12)),
              ),
              ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                child: const Text('Enregistrer'),
              ),
              if (hasInitial)
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, const PhotoTextSaved(null)),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.textMedium),
                  child: const Text('Supprimer le texte'),
                ),
              const Divider(height: 24, color: AppColors.border),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(
                          context, const PhotoFeaturedToggled()),
                      icon: Icon(
                          widget.featured
                              ? Icons.grid_view_rounded
                              : Icons.fullscreen,
                          size: 18),
                      label: Text(widget.featured
                          ? 'Remettre en petit'
                          : 'Mettre en grand'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          Navigator.pop(context, const PhotoRemoved()),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Retirer du livre'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: const BorderSide(color: AppColors.error),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
