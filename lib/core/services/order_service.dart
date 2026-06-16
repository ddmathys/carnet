import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/order_model.dart';
import 'backend_client.dart';

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
            final list = s.docs.map((d) => OrderModel.fromFirestore(d)).toList();
            list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
            return list;
          });
}
