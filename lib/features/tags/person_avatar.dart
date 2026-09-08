import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/app_messenger.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/space_service.dart';
import '../../core/services/tag_service.dart';
import '../../core/theme/app_theme.dart';

/// Cache des URLs signées des photos de personne — mêmes clés R2
/// (`photos/{uid}/…`) que les photos de souvenir, signées via
/// [PhotoService.signOwnPhotoKeys]. Session-only : une pastille déjà affichée
/// n'est pas re-signée à chaque reconstruction/scroll.
class PersonPhotoCache {
  PersonPhotoCache._();
  static final Map<String, String> _urls = {};
  static final Map<String, Future<String?>> _inflight = {};

  static Future<String?> urlFor(String key) {
    final cached = _urls[key];
    if (cached != null) return Future.value(cached);
    return _inflight.putIfAbsent(key, () async {
      final map = await PhotoService.signOwnPhotoKeys([key]);
      final url = map[key];
      if (url != null) _urls[key] = url;
      _inflight.remove(key);
      return url;
    });
  }

  static void invalidate(String key) => _urls.remove(key);
}

/// La « pastille » d'une personne : sa photo de tête si elle en a une, sinon
/// un rond de couleur avec son initiale (même palette que ses tags).
class PersonAvatar extends StatelessWidget {
  final String label;
  final String? photoKey;
  final String colorHex;
  final double size;

  const PersonAvatar({
    super.key,
    required this.label,
    this.photoKey,
    this.colorHex = '#C4714B',
    this.size = 22,
  });

  Color get _color {
    final hex = colorHex.replaceFirst('#', '');
    final parsed = int.tryParse('FF$hex', radix: 16);
    return parsed != null ? Color(parsed) : AppColors.sageDark;
  }

  @override
  Widget build(BuildContext context) {
    final key = photoKey;
    if (key == null || key.isEmpty) return _fallback();
    return FutureBuilder<String?>(
      future: PersonPhotoCache.urlFor(key),
      builder: (context, snap) {
        final url = snap.data;
        if (url == null) return _fallback();
        return CircleAvatar(
          radius: size / 2,
          backgroundColor: AppColors.softGray,
          backgroundImage: NetworkImage(url),
        );
      },
    );
  }

  Widget _fallback() => CircleAvatar(
        radius: size / 2,
        backgroundColor: _color,
        child: Text(
          label.trim().isNotEmpty ? label.trim()[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.45,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

/// Ouvre galerie/appareil photo, recadre en cercle (tête), uploade vers R2 et
/// enregistre la clé sur le tag. Renvoie le tag mis à jour, ou null si annulé
/// à une étape quelconque du choix/recadrage. Un échec d'upload (réseau) est
/// signalé par un SnackBar avant de renvoyer null — jamais silencieux.
Future<TagModel?> editPersonPhoto(BuildContext context, TagModel tag) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.softGray,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Photo de « ${tag.label} »',
                style: const TextStyle(
                  fontFamily: 'Fraunces',
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          ListTile(
            leading:
                const Icon(Icons.perm_media_outlined, color: AppColors.sage),
            title: const Text('Choisir dans la galerie'),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          ListTile(
            leading:
                const Icon(Icons.add_a_photo_outlined, color: AppColors.sage),
            title: const Text('Prendre une photo'),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;

  final picked =
      await ImagePicker().pickImage(source: source, imageQuality: 95);
  if (picked == null || !context.mounted) return null;

  final cropped = await ImageCropper().cropImage(
    sourcePath: picked.path,
    compressFormat: ImageCompressFormat.jpg,
    compressQuality: 90,
    aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: 'Recadrer la tête',
        toolbarColor: AppColors.sageDark,
        toolbarWidgetColor: Colors.white,
        lockAspectRatio: true,
        cropStyle: CropStyle.circle,
      ),
      IOSUiSettings(
        title: 'Recadrer la tête',
        aspectRatioLockEnabled: true,
        resetAspectRatioEnabled: false,
        cropStyle: CropStyle.circle,
      ),
    ],
  );
  if (cropped == null || !context.mounted) return null;

  final spaceId = await SpaceService.ensureSpaceId();
  if (spaceId == null) {
    appMessengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('Espace introuvable')),
    );
    return null;
  }
  final key = await PhotoService.uploadMemoryPhotoToR2(
    photo: File(cropped.path),
    notebookId: spaceId,
  );
  if (key == null) {
    appMessengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('Échec de l\'envoi de la photo')),
    );
    return null;
  }

  final oldKey = tag.photoKey;
  await TagService.setPersonPhoto(tag, key);
  if (oldKey != null && oldKey.isNotEmpty) {
    PersonPhotoCache.invalidate(oldKey);
    // Best effort : l'ancienne photo ne sert plus à rien.
    PhotoService.deletePhotoByKey(oldKey);
  }

  return TagModel(
    id: tag.id,
    userId: tag.userId,
    label: tag.label,
    kind: tag.kind,
    color: tag.color,
    photoKey: key,
    birthdate: tag.birthdate,
    gender: tag.gender,
    companion: tag.companion,
    companionName: tag.companionName,
    sharedWith: tag.sharedWith,
    invitedEmails: tag.invitedEmails,
    createdAt: tag.createdAt,
  );
}
