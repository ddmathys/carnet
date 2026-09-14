import 'dart:io';
import 'package:flutter/foundation.dart';
import 'photo_service.dart';
import 'video_service.dart';
import 'video_upload_lane.dart';

enum DraftUploadStatus { uploading, done, failed, cancelled }

/// Suivi d'UN média sélectionné dans l'écran de création dont l'envoi vers R2
/// démarre IMMÉDIATEMENT — pas seulement au moment d'« Enregistrer ». Le
/// temps passé à remplir le reste du formulaire (titre, date, lieu…) sert
/// aussi à l'envoi : la file qui restait à traiter APRÈS la sauvegarde
/// (bannière « Envoi de la vidéo x/y », voir `UploadStatusBanner`) est donc
/// souvent bien plus courte, parfois vide, une fois qu'on appuie sur
/// « Enregistrer ».
class DraftUploadTicket extends ChangeNotifier {
  DraftUploadTicket({required this.isVideo});

  final bool isVideo;
  DraftUploadStatus status = DraftUploadStatus.uploading;
  String? key;
  int? durationMs;
  bool _cancelRequested = false;

  bool get isCancelled => _cancelRequested;
  bool get isDone => status == DraftUploadStatus.done;

  void _markDone(String uploadedKey, int? uploadedDurationMs) {
    key = uploadedKey;
    durationMs = uploadedDurationMs;
    final cancelledMeanwhile = _cancelRequested;
    status =
        cancelledMeanwhile ? DraftUploadStatus.cancelled : DraftUploadStatus.done;
    notifyListeners();
    if (cancelledMeanwhile) {
      // Désélectionné pendant que l'envoi se terminait : la clé est déjà sur
      // R2, on la nettoie plutôt que de laisser un objet orphelin.
      if (isVideo) {
        VideoService.deleteVideoByKey(uploadedKey);
      } else {
        PhotoService.deletePhotoByKey(uploadedKey);
      }
    }
  }

  void _markFailed() {
    if (_cancelRequested) {
      status = DraftUploadStatus.cancelled;
    } else {
      status = DraftUploadStatus.failed;
    }
    notifyListeners();
  }

  void _markCancelled() {
    status = DraftUploadStatus.cancelled;
    notifyListeners();
  }
}

/// Démarre l'envoi d'une photo/vidéo dès sa sélection dans l'écran de
/// création. Les vidéos passent par [VideoUploadLane] (partagé avec
/// `MediaUploadQueue`) pour respecter la contrainte d'une seule session de
/// compression native à la fois, app-wide.
class DraftMediaUploader {
  DraftMediaUploader._();
  static final DraftMediaUploader instance = DraftMediaUploader._();

  /// [notebookId] est un [Future] (généralement déjà résolu depuis le cache
  /// de `SpaceService`) pour que le ticket existe tout de suite, de façon
  /// SYNCHRONE — l'appelant l'ajoute à une liste parallèle aux fichiers
  /// locaux dans le même `setState`, avant même de savoir dans quel carnet
  /// le média finira.
  DraftUploadTicket startPhoto(
      {required File file, required Future<String?> notebookId}) {
    final ticket = DraftUploadTicket(isVideo: false);
    // Photos : upload court, pas de mécanisme d'annulation en cours de route
    // (comme le reste de l'app pour les photos) — seul le nettoyage après
    // coup (clé déjà obtenue) est géré, dans `_markDone`.
    () async {
      final nbId = await notebookId;
      if (nbId == null) {
        ticket._markFailed();
        return;
      }
      final uploadedKey =
          await PhotoService.uploadMemoryPhotoToR2(photo: file, notebookId: nbId);
      if (uploadedKey == null) {
        ticket._markFailed();
      } else {
        ticket._markDone(uploadedKey, null);
      }
    }();
    return ticket;
  }

  /// Voir [startPhoto] pour [notebookId].
  DraftUploadTicket startVideo(
      {required File file, required Future<String?> notebookId}) {
    final ticket = DraftUploadTicket(isVideo: true);
    () async {
      final nbId = await notebookId;
      if (nbId == null) {
        ticket._markFailed();
        return;
      }
      await VideoUploadLane.instance.run(() async {
        if (ticket.isCancelled) {
          ticket._markCancelled();
          return;
        }
        final r = await VideoService.uploadMemoryVideo(
          video: file,
          notebookId: nbId,
          isCancelled: () => ticket.isCancelled,
        );
        if (r == null) {
          if (VideoService.lastUploadWasCancelled) {
            ticket._markCancelled();
          } else {
            ticket._markFailed();
          }
        } else {
          ticket._markDone(r.key, r.durationMs);
        }
      });
    }();
    return ticket;
  }

  /// Annule un ticket : s'il n'a pas encore démarré ou est en cours d'envoi,
  /// il s'arrête au prochain point de contrôle ; s'il a déjà produit une clé
  /// R2, elle est supprimée du stockage. Sûr à appeler plusieurs fois ou
  /// après coup.
  void cancel(DraftUploadTicket ticket) {
    ticket._cancelRequested = true;
    if (ticket.status == DraftUploadStatus.done && ticket.key != null) {
      if (ticket.isVideo) {
        VideoService.deleteVideoByKey(ticket.key);
      } else {
        PhotoService.deletePhotoByKey(ticket.key);
      }
    }
  }
}
