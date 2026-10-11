import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mesure d'usage (Firebase Analytics / GA4).
///
/// Posé le 11.10.26. Jusque-là l'application n'avait AUCUNE mesure d'usage —
/// seulement Crashlytics : on savait quand ça plantait, pas combien de gens
/// installaient, créaient un souvenir, ouvraient l'aperçu d'un livre ou
/// payaient. Impossible dans ces conditions de savoir quel canal de
/// communication rapporte, donc impossible de dépenser en publicité sans
/// gaspiller.
///
/// ── Les cinq étapes de l'entonnoir ────────────────────────────────────────
///   1. `first_open`           — installation. Émis AUTOMATIQUEMENT par
///                               Firebase, rien à coder (ne jamais le logger
///                               à la main : ça le dédoublerait).
///   2. `memory_created`       — un souvenir est né (le geste de base).
///   3. `book_preview_opened`  — l'aperçu d'un livre s'est affiché : la
///                               première vraie intention d'achat.
///   4. `checkout_started`     — la page de paiement Stripe s'ouvre.
///   5. `order_paid`           — le paiement est passé.
///
/// Le chiffre d'affaires exact ne se lit PAS ici : Analytics est échantillonné,
/// différé de quelques heures, et `order_paid` dépend du retour de
/// l'utilisateur dans l'app (voir [logOrderPaid]). La vérité comptable reste
/// Firestore (`orders`), lue par la console admin — voir
/// `admin_dashboard_screen.dart`.
class AnalyticsService {
  static final FirebaseAnalytics _ga = FirebaseAnalytics.instance;

  /// Observateur à brancher sur GoRouter : enregistre `screen_view` à chaque
  /// navigation, sans une ligne de code par écran.
  static FirebaseAnalyticsObserver get observer =>
      FirebaseAnalyticsObserver(analytics: _ga);

  /// Rien n'est envoyé depuis un build de debug — même règle que Crashlytics
  /// (`main.dart`) : les allers-retours de développement n'ont pas à polluer
  /// les chiffres de production.
  static Future<void> init() async {
    await _ga.setAnalyticsCollectionEnabled(!kDebugMode);
  }

  /// Envoi silencieux : une mesure qui échoue ne doit JAMAIS casser un geste
  /// utilisateur (enregistrer un souvenir, payer…).
  static Future<void> _log(String name, [Map<String, Object>? params]) async {
    if (kDebugMode) {
      debugPrint('[analytics] $name ${params ?? ''}');
      return;
    }
    try {
      await _ga.logEvent(name: name, parameters: params);
    } catch (e) {
      debugPrint('[analytics] échec $name: $e');
    }
  }

  // ── 2. Souvenir créé ───────────────────────────────────────────────────────

  /// À la CRÉATION seulement, jamais à la modification d'un souvenir existant.
  /// [type] est la catégorie (`anecdote`, `taille_poids`…) : elle dit quels
  /// usages portent réellement l'app.
  static Future<void> logMemoryCreated({
    required String type,
    required int photoCount,
    required int videoCount,
    required bool hasAudio,
  }) =>
      _log('memory_created', {
        'memory_type': type,
        'photo_count': photoCount,
        'video_count': videoCount,
        'has_audio': hasAudio ? 1 : 0,
      });

  // ── 3. Aperçu d'un produit imprimé ─────────────────────────────────────────

  /// L'aperçu s'est affiché pour de bon (PDF généré, pas seulement demandé).
  /// [productType] vaut `book` aujourd'hui ; poster et puzzle n'ont pas le même
  /// cycle d'aperçu et pourront appeler cette même méthode le jour où on les
  /// instrumente.
  static Future<void> logBookPreviewOpened({
    String productType = 'book',
    required int pageCount,
    required int photoCount,
    required int memoryCount,
  }) =>
      _log('book_preview_opened', {
        'product_type': productType,
        'page_count': pageCount,
        'photo_count': photoCount,
        'memory_count': memoryCount,
      });

  // ── 4. Paiement lancé ──────────────────────────────────────────────────────

  /// La page Stripe s'ouvre. On émet AUSSI `begin_checkout`, le nom standard
  /// GA4 : c'est lui — et pas un nom maison — que les rapports d'entonnoir et
  /// de valeur de Firebase savent lire.
  static Future<void> logCheckoutStarted({
    required String productType,
    required double value,
  }) async {
    final params = <String, Object>{
      'product_type': productType,
      'value': value,
      'currency': 'CHF',
    };
    await _log('checkout_started', params);
    await _log('begin_checkout', params);
  }

  // ── 5. Commande payée ──────────────────────────────────────────────────────

  /// Paiement confirmé. Deux limites assumées :
  ///
  ///  - le paiement se fait dans le NAVIGATEUR (Stripe Checkout ouvert par
  ///    `url_launcher`), donc cet événement ne part que quand l'utilisateur
  ///    revient dans l'app et voit sa commande passée à « payé ». Il
  ///    sous-compte donc par nature → pour le chiffre d'affaires, se fier au
  ///    tableau de bord admin (Firestore), pas à Analytics ;
  ///  - il ne doit partir QU'UNE FOIS par commande, alors que l'écran de suivi
  ///    se reconstruit à chaque passage. D'où la liste des commandes déjà
  ///    comptées, gardée sur l'appareil.
  ///
  /// `purchase` est le nom standard GA4, émis en plus pour la même raison que
  /// `begin_checkout` ci-dessus.
  static Future<void> logOrderPaid({
    required String orderId,
    required String productType,
    required double value,
  }) async {
    if (!await _markOnce('order_paid', orderId)) return;
    final params = <String, Object>{
      'product_type': productType,
      'value': value,
      'currency': 'CHF',
      'transaction_id': orderId,
    };
    await _log('order_paid', params);
    await _log('purchase', params);
  }

  /// Retourne true la première fois seulement pour ce couple ([event], [id]).
  /// Garde-fou anti-doublon qui survit au redémarrage de l'app.
  static Future<bool> _markOnce(String event, String id) async {
    final key = 'analytics_once_$event';
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getStringList(key) ?? <String>[];
      if (seen.contains(id)) return false;
      // Borné : on ne garde que les 200 derniers, inutile de faire grossir
      // les préférences indéfiniment.
      final next = [...seen, id];
      await prefs.setStringList(
        key,
        next.length > 200 ? next.sublist(next.length - 200) : next,
      );
      return true;
    } catch (_) {
      // Pas de préférences accessibles → on préfère un doublon possible à un
      // événement perdu.
      return true;
    }
  }
}
