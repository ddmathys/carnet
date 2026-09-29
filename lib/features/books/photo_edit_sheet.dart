import 'package:flutter/material.dart';
import '../../core/models/book_draft.dart';
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

/// Feuille « cette photo » : texte posé sur la photo (couleur, position,
/// bandeau), mise en grand, retrait du livre.
class PhotoEditSheet extends StatefulWidget {
  final BookPhotoText? initial;
  final bool featured;

  const PhotoEditSheet({super.key, this.initial, this.featured = false});

  static Future<PhotoEditResult?> open(
    BuildContext context, {
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
        builder: (_) => PhotoEditSheet(initial: initial, featured: featured),
      );

  @override
  State<PhotoEditSheet> createState() => _PhotoEditSheetState();
}

class _PhotoEditSheetState extends State<PhotoEditSheet> {
  late final TextEditingController _textCtrl;
  late String _color;
  late String _position;
  late bool _background;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _textCtrl = TextEditingController(text: t?.text ?? '');
    _color = t?.color ?? BookPhotoText.palette.first;
    _position = t?.position ?? 'bottom';
    _background = t?.background ?? true;
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
              position: _position,
              background: _background,
            )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _hex(_color);
    // Même règle de contraste que le PDF (BookPdfService._photoTextBox).
    final bg = color.computeLuminance() > 0.5 ? AppColors.ink : Colors.white;
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
              const SizedBox(height: 14),
              const Text(
                'Texte sur la photo',
                style: TextStyle(
                  fontFamily: 'PlayfairDisplay',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark,
                ),
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
              // Aperçu du rendu (couleur + bandeau), sur un fond « photo ».
              if (_textCtrl.text.trim().isNotEmpty)
                Container(
                  height: 64,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF7FA7C9), Color(0xFFD9B98C)],
                    ),
                  ),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    padding: _background
                        ? const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5)
                        : EdgeInsets.zero,
                    color: _background ? bg : null,
                    child: Text(
                      _textCtrl.text.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'PlayfairDisplay',
                          fontSize: 15,
                          color: color),
                    ),
                  ),
                ),
              const Text('Couleur',
                  style: TextStyle(color: AppColors.textMedium, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final hex in BookPhotoText.palette)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: GestureDetector(
                        onTap: () => setState(() => _color = hex),
                        child: Container(
                          width: 36,
                          height: 36,
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
              const SizedBox(height: 14),
              Row(
                children: [
                  const Text('Position',
                      style:
                          TextStyle(color: AppColors.textMedium, fontSize: 13)),
                  const Spacer(),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'top', label: Text('En haut')),
                      ButtonSegment(value: 'bottom', label: Text('En bas')),
                    ],
                    selected: {_position},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) =>
                        setState(() => _position = v.first),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _background,
                onChanged: (v) => setState(() => _background = v),
                title: const Text('Bandeau derrière le texte',
                    style: TextStyle(color: AppColors.textDark, fontSize: 14)),
                subtitle: const Text('Plus lisible une fois imprimé',
                    style:
                        TextStyle(color: AppColors.textMedium, fontSize: 12)),
              ),
              const SizedBox(height: 8),
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
                      onPressed: () =>
                          Navigator.pop(context, const PhotoFeaturedToggled()),
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
