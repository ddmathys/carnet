import 'dart:typed_data';

/// Lit (largeur, hauteur) en pixels depuis les en-têtes PNG/JPEG — sans
/// package. Extrait de BookPdfService (usage identique) pour être réutilisé
/// par PosterQualityService (contrôle qualité DPI par taille).
({int w, int h})? imageDims(Uint8List bytes) {
  if (bytes.length < 4) return null;
  // PNG : 89 50 4E 47 … largeur [16..19], hauteur [20..23]
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes.length >= 24) {
    final w =
        (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final h =
        (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
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
