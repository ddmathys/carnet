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

  /// Supprime la commande (ex. après suppression côté Gelato) : le PDF
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
          await PdfService.deleteBookPdf(r2Key);
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

  // ── Envoyer à Gelato (admin) ──────────────────────────────────────────────

  /// Crée la commande chez Gelato via le backend. `orderType` = 'draft' par
  /// défaut (brouillon à valider dans le dashboard Gelato) ou 'order' pour
  /// commander directement en production. Lève une exception en cas d'échec.
  static Future<Map<String, dynamic>> sendToGelato(
    String orderId, {
    String orderType = 'draft',
  }) async {
    final data = await BackendClient.postJson(
      '/api/gelato/order',
      {'orderId': orderId, 'orderType': orderType},
      timeout: const Duration(seconds: 30),
    );
    if (data == null || data['ok'] != true) {
      throw Exception(data?['error'] ?? data?['detail'] ?? 'Échec Gelato');
    }
    return data;
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
