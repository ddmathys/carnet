import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'backend_client.dart';

/// À quelle fréquence l'utilisateur veut recevoir son « souvenir du jour ».
enum NotifyFrequency { none, daily, weekly }

extension NotifyFrequencyX on NotifyFrequency {
  /// Valeur écrite dans Firestore — c'est elle que lit le cron du backend.
  String get storageValue => switch (this) {
        NotifyFrequency.none => 'none',
        NotifyFrequency.daily => 'daily',
        NotifyFrequency.weekly => 'weekly',
      };

  String get label => switch (this) {
        NotifyFrequency.none => 'Jamais',
        NotifyFrequency.daily => 'Chaque jour',
        NotifyFrequency.weekly => 'Une fois par semaine',
      };

  static NotifyFrequency fromStorage(Object? value) => switch (value) {
        'daily' => NotifyFrequency.daily,
        'weekly' => NotifyFrequency.weekly,
        _ => NotifyFrequency.none,
      };
}

/// Notifications « souvenir du jour » : une photo au hasard ressortie du carnet,
/// façon Google Photos.
///
/// L'envoi est fait par le BACKEND (cron quotidien `/api/notify/cron`), pas par
/// le téléphone : la notification arrive même si l'appli n'a pas été ouverte
/// depuis des semaines. Cette classe ne gère donc que le côté appareil :
///  - demander l'autorisation système ;
///  - enregistrer le jeton FCM de l'appareil dans `users/{uid}.fcmTokens` ;
///  - stocker la fréquence choisie dans `users/{uid}.notifyFrequency` ;
///  - ouvrir le bon souvenir quand on tape la notification.
class NotificationService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static FirebaseMessaging get _fcm => FirebaseMessaging.instance;

  static StreamSubscription<String>? _tokenSub;

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ── Autorisation système ────────────────────────────────────────────────

  /// L'utilisateur a-t-il déjà accordé les notifications ? (Sans rien demander.)
  static Future<bool> isAuthorized() async {
    try {
      final settings = await _fcm.getNotificationSettings();
      return _granted(settings);
    } catch (_) {
      return false;
    }
  }

  /// Affiche la demande d'autorisation système. Sur Android 13+ et sur iOS,
  /// elle ne peut être posée qu'une fois : si l'utilisateur refuse, il faudra
  /// passer par les réglages du téléphone.
  static Future<bool> requestPermission() async {
    try {
      final settings = await _fcm.requestPermission();
      return _granted(settings);
    } catch (_) {
      return false;
    }
  }

  static bool _granted(NotificationSettings s) =>
      s.authorizationStatus == AuthorizationStatus.authorized ||
      s.authorizationStatus == AuthorizationStatus.provisional;

  // ── Préférence de l'utilisateur ─────────────────────────────────────────

  /// Fréquence enregistrée pour le compte courant.
  static Future<NotifyFrequency> currentFrequency() async {
    final uid = _uid;
    if (uid == null) return NotifyFrequency.none;
    try {
      final doc = await _db.collection('users').doc(uid).get();
      return NotifyFrequencyX.fromStorage(doc.data()?['notifyFrequency']);
    } catch (_) {
      return NotifyFrequency.none;
    }
  }

  /// Enregistre le choix. Renvoie `false` si l'utilisateur a refusé
  /// l'autorisation système — dans ce cas rien n'est enregistré, pour ne pas
  /// afficher « chaque jour » alors qu'aucune notification ne pourra arriver.
  static Future<bool> setFrequency(NotifyFrequency frequency) async {
    final uid = _uid;
    if (uid == null) return false;

    if (frequency != NotifyFrequency.none) {
      final allowed = await isAuthorized() || await requestPermission();
      if (!allowed) return false;
      await _registerToken(uid);
    }

    try {
      await _db.collection('users').doc(uid).set(
        {'notifyFrequency': frequency.storageValue},
        SetOptions(merge: true),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Déclenche un envoi immédiat à soi-même (bouton "Envoyer maintenant" du
  /// profil) — sert à vérifier tout de suite que ça marche plutôt que
  /// d'attendre le cron quotidien (7h UTC). Lève une exception avec le
  /// message d'erreur du backend en cas d'échec (aucun appareil enregistré,
  /// aucun souvenir avec photo…).
  static Future<void> sendNow() async {
    final data = await BackendClient.postJson('/api/notify/send-now', {});
    if (data == null || data['ok'] != true) {
      throw Exception('Envoi impossible — vérifie que les notifications sont activées.');
    }
  }

  // ── Jeton de l'appareil ─────────────────────────────────────────────────

  /// Le jeton identifie CET appareil. Un même compte peut en avoir plusieurs
  /// (téléphone + tablette), d'où une liste plutôt qu'un champ unique.
  static Future<void> _registerToken(String uid) async {
    try {
      final token = await _fcm.getToken();
      if (token == null || token.isEmpty) return;
      await _db.collection('users').doc(uid).set(
        {'fcmTokens': FieldValue.arrayUnion([token])},
        SetOptions(merge: true),
      );
    } catch (_) {
      // Pas de jeton (iOS sans APNs configuré, appareil sans Play Services) :
      // le reste de l'appli n'en souffre pas.
    }
  }

  /// À appeler au démarrage, une fois l'utilisateur connu. Ne réclame JAMAIS
  /// d'autorisation : on se contente de rafraîchir le jeton de ceux qui ont
  /// déjà dit oui, car un jeton FCM peut changer tout seul.
  static Future<void> syncOnLogin() async {
    final uid = _uid;
    if (uid == null) return;
    final frequency = await currentFrequency();
    if (frequency == NotifyFrequency.none) return;
    if (!await isAuthorized()) return;

    await _registerToken(uid);
    _tokenSub ??= _fcm.onTokenRefresh.listen((token) async {
      final current = _uid;
      if (current == null || token.isEmpty) return;
      await _db.collection('users').doc(current).set(
        {'fcmTokens': FieldValue.arrayUnion([token])},
        SetOptions(merge: true),
      ).catchError((_) {});
    });
  }

  /// Au moment de se déconnecter : cet appareil ne doit plus recevoir les
  /// souvenirs du compte qu'on quitte.
  static Future<void> forgetDevice() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final token = await _fcm.getToken();
      if (token == null || token.isEmpty) return;
      await _db.collection('users').doc(uid).set(
        {'fcmTokens': FieldValue.arrayRemove([token])},
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  // ── Ouverture du souvenir au tap ────────────────────────────────────────

  /// Souvenir visé par la notification qui a lancé l'appli (appli fermée).
  static Future<String?> initialMemoryId() async {
    try {
      final message = await _fcm.getInitialMessage();
      return _memoryIdOf(message);
    } catch (_) {
      return null;
    }
  }

  /// Notification tapée alors que l'appli tournait déjà (au premier plan ou en
  /// arrière-plan).
  static StreamSubscription<RemoteMessage> listenTaps(
    void Function(String memoryId) onOpen,
  ) {
    return FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final id = _memoryIdOf(message);
      if (id != null) onOpen(id);
    });
  }

  static String? _memoryIdOf(RemoteMessage? message) {
    final id = message?.data['memoryId'];
    return (id is String && id.isNotEmpty) ? id : null;
  }
}
