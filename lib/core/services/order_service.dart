import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import '../models/order_model.dart';
import 'backend_client.dart';
import 'pdf_service.dart';

class OrderService {
  // ── Créer une commande ─────────────────────────────────────────────────────

  static Future<String> createOrder(OrderModel order) async {
    final ref = await FirebaseFirestore.instance
        .collection('orders')
        .add(order.toFirestore());

    // Emails (admin + client) envoyés par le backend — non bloquant
    _sendOrderEmails(ref.id);

    return ref.id;
  }

  static Future<void> _sendOrderEmails(String orderId) async {
    try {
      final data = await BackendClient.postJson(
        '/api/email/order',
        {'orderId': orderId},
        timeout: const Duration(seconds: 20),
      );
      if (data?['ok'] != true) {
        debugPrint('[email/order] envoi partiel ou échoué: $data');
      }
    } catch (e) {
      debugPrint('[email/order] ERROR: $e');
    }
  }

  // ── Supprimer une commande (admin) ────────────────────────────────────────

  /// Supprime la commande (ex. après suppression côté imprimeur) : le PDF
  /// (best-effort) puis le document Firestore. Réservé à l'admin par les règles.
  ///
  /// Le PDF vit sur R2 (URL stable `…/book-pdf?key=…`) ; les commandes d'avant
  /// la bascule ont encore une URL Firebase.
  static Future<void> deleteOrder(OrderModel order) async {
    final url = order.pdfUrl;
    if (url != null && url.isNotEmpty) {
      try {
        final r2Key = PdfService.keyFromUrl(url);
        if (r2Key != null) {
          if (order.isPoster) {
            await PdfService.deletePosterPdf(r2Key);
          } else {
            await PdfService.deleteBookPdf(r2Key);
          }
        } else {
          await FirebaseStorage.instance.refFromURL(url).delete();
        }
      } catch (e) {
        debugPrint('[orders] PDF non supprimé (${order.id}): $e');
      }
    }
    await FirebaseFirestore.instance.collection('orders').doc(order.id).delete();
  }

  // ── Paiement (TWINT / carte via Stripe Checkout) ──────────────────────────

  /// Crée une session de paiement Stripe pour la commande et renvoie l'URL
  /// hébergée (à ouvrir dans le navigateur). null si échec/non configuré.
  static Future<String?> createCheckout(String orderId) async {
    final data = await BackendClient.postJson(
      '/api/payment/checkout',
      {'orderId': orderId},
      timeout: const Duration(seconds: 30),
    );
    return data?['url'] as String?;
  }

  // ── Mettre à jour le statut (admin) ───────────────────────────────────────

  static Future<void> updateStatus(String orderId, String status, {String? adminNote}) async {
    final data = <String, dynamic>{
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (adminNote != null) data['adminNote'] = adminNote;
    await FirebaseFirestore.instance.collection('orders').doc(orderId).update(data);
  }

  // ── Envoyer à l'impression (admin) ────────────────────────────────────────

  /// Envoie la commande à Prodigi via le backend, en un seul appel (pas de
  /// brouillon à confirmer comme avec Gelato). Le backend refuse si la
  /// commande n'est pas encore marquée "payée". `pdfUrl`/`pageCount` : à
  /// fournir uniquement pour un RENVOI après erreur avec un livre régénéré
  /// (voir book_generate_screen.dart en mode édition) — le backend plafonne
  /// alors à 3 tentatives. Lève une exception en cas d'échec.
  static Future<Map<String, dynamic>> sendToPrint(
    String orderId, {
    String? pdfUrl,
    int? pageCount,
  }) async {
    final data = await BackendClient.postJson(
      '/api/prodigi/order',
      {
        'orderId': orderId,
        if (pdfUrl != null) 'pdfUrl': pdfUrl,
        if (pageCount != null) 'pageCount': pageCount,
      },
      timeout: const Duration(seconds: 30),
    );
    if (data == null || data['ok'] != true) {
      throw Exception(data?['error'] ?? data?['detail'] ?? 'Échec de l’envoi à l’impression');
    }
    return data;
  }

  /// Vérifie notre prix/nombre de pages contre un vrai devis Prodigi (admin,
  /// gratuit, ne modifie rien) — pour confirmer avant l'envoi réel que
  /// book_pricing.dart n'a pas divergé du tarif Prodigi actuel.
  static Future<Map<String, dynamic>> verifyPrintQuote({
    required String coverType,
    required int pageCount,
    String? country,
  }) async {
    final data = await BackendClient.postJson(
      '/api/prodigi/quote',
      {
        'coverType': coverType,
        'pageCount': pageCount,
        if (country != null) 'country': country,
      },
      timeout: const Duration(seconds: 20),
    );
    if (data == null || data['ok'] != true) {
      throw Exception(data?['error'] ?? data?['detail'] ?? 'Échec du devis Prodigi');
    }
    return data;
  }

  /// Le client confirme avoir reçu sa commande expédiée ("J'ai bien reçu ma
  /// commande") : passe le statut à 'archived' côté backend (Admin SDK — le
  /// client n'a pas le droit d'écrire `orders` directement, voir
  /// firestore.rules) et prévient l'admin par mail. Lève une exception si le
  /// backend refuse (commande pas encore expédiée, ou pas la sienne).
  static Future<void> confirmDelivery(String orderId) async {
    final data = await BackendClient.postJson(
      '/api/notify/order-received',
      {'orderId': orderId},
      timeout: const Duration(seconds: 20),
    );
    if (data == null || data['ok'] != true) {
      throw Exception(data?['error'] ?? 'Échec de la confirmation');
    }
  }

  /// Le client annule sa commande avant paiement ("Annuler la commande").
  /// Passe par le backend (Admin SDK) car le client n'a pas le droit de
  /// supprimer `orders` directement (Firestore rules : delete admin-only) —
  /// avant ce fix, ce bouton échouait silencieusement pour un vrai client.
  static Future<void> cancelOrder(String orderId) async {
    final data = await BackendClient.postJson(
      '/api/notify/order-cancel',
      {'orderId': orderId},
      timeout: const Duration(seconds: 20),
    );
    if (data == null || data['ok'] != true) {
      throw Exception(data?['error'] ?? 'Échec de l\'annulation');
    }
  }

  /// Relit le vrai statut d'une commande chez Prodigi (admin, ou le client
  /// pour la sienne) — utile pour un rafraîchissement manuel sans attendre
  /// le cron quotidien.
  static Future<Map<String, dynamic>> checkPrintStatus(String orderId) async {
    final data = await BackendClient.postJson(
      '/api/prodigi/status',
      {'orderId': orderId},
      timeout: const Duration(seconds: 20),
    );
    if (data == null || data['ok'] != true) {
      throw Exception(data?['error'] ?? 'Échec de la vérification');
    }
    return data;
  }

  /// Lecture ponctuelle d'une commande (pas un stream) — utilisée pour
  /// pré-remplir l'écran d'édition d'un livre refusé (adresse, couverture…).
  static Future<OrderModel?> getOrder(String orderId) async {
    final doc =
        await FirebaseFirestore.instance.collection('orders').doc(orderId).get();
    if (!doc.exists) return null;
    return OrderModel.fromFirestore(doc);
  }

  // ── Streams ────────────────────────────────────────────────────────────────

  // Tri client-side — pas besoin d'index composite Firestore
  static Stream<List<OrderModel>> userOrdersStream(String userId) =>
      FirebaseFirestore.instance
          .collection('orders')
          .where('userId', isEqualTo: userId)
          .snapshots()
          .map((s) {
            final list = s.docs.map((d) => OrderModel.fromFirestore(d)).toList();
            list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
            return list;
          });

  static Stream<List<OrderModel>> allOrdersStream() =>
      FirebaseFirestore.instance
          .collection('orders')
          .snapshots()
          .map((s) {
            // Parsing résilient : un doc malformé ne doit pas casser tout le flux.
            final list = <OrderModel>[];
            for (final d in s.docs) {
              try {
                list.add(OrderModel.fromFirestore(d));
              } catch (e) {
                debugPrint('[orders] doc ${d.id} ignoré: $e');
              }
            }
            list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
            return list;
          });
}
