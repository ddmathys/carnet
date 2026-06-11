import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import '../models/order_model.dart';
import '../config/app_config.dart';

class OrderService {
  static const _adminEmail = 'david.mathys24@gmail.com';
  static const _fromEmail = 'Carnet <noreply@dmathys.dev>';
  static const _resendUrl = 'https://api.resend.com/emails';

  // ── Créer une commande ─────────────────────────────────────────────────────

  static Future<String> createOrder(OrderModel order) async {
    final ref = await FirebaseFirestore.instance
        .collection('orders')
        .add(order.toFirestore());

    // Emails en parallèle — non bloquants
    _sendAdminNotification(order.copyWith(id: ref.id));
    _sendUserConfirmation(order.copyWith(id: ref.id));

    return ref.id;
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

  // ── Email admin ────────────────────────────────────────────────────────────

  static Future<void> _sendAdminNotification(OrderModel o) async {
    final html = '''
<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8"/></head>
<body style="margin:0;padding:0;background:#f5ece0;font-family:Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="padding:40px 0;">
  <tr><td align="center">
    <table width="520" cellpadding="0" cellspacing="0"
           style="background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
      <tr><td style="background:#3A6648;padding:28px 36px;">
        <p style="margin:0;font-size:22px;font-weight:bold;color:#FFF8E8;font-style:italic;">carnet</p>
        <p style="margin:6px 0 0;color:rgba(255,248,232,.8);font-size:13px;">🎉 Nouvelle commande reçue</p>
      </td></tr>
      <tr><td style="padding:28px 36px;">
        <table width="100%" style="border-collapse:collapse;">
          <tr><td style="padding:8px 0;border-bottom:1px solid #eee;color:#888;font-size:13px;">Commande</td>
              <td style="padding:8px 0;border-bottom:1px solid #eee;font-weight:bold;font-size:13px;">#${o.id.substring(0, 8).toUpperCase()}</td></tr>
          <tr><td style="padding:8px 0;border-bottom:1px solid #eee;color:#888;font-size:13px;">Client</td>
              <td style="padding:8px 0;border-bottom:1px solid #eee;font-size:13px;">${o.fullName} · ${o.userEmail}</td></tr>
          <tr><td style="padding:8px 0;border-bottom:1px solid #eee;color:#888;font-size:13px;">Livre</td>
              <td style="padding:8px 0;border-bottom:1px solid #eee;font-size:13px;">${o.bookTitle}</td></tr>
          <tr><td style="padding:8px 0;border-bottom:1px solid #eee;color:#888;font-size:13px;">Couverture</td>
              <td style="padding:8px 0;border-bottom:1px solid #eee;font-size:13px;">${o.coverType == 'hard' ? 'Rigide' : 'Souple'}</td></tr>
          <tr><td style="padding:8px 0;border-bottom:1px solid #eee;color:#888;font-size:13px;">Adresse</td>
              <td style="padding:8px 0;border-bottom:1px solid #eee;font-size:13px;">${o.fullAddress}</td></tr>
          <tr><td style="padding:8px 0;color:#888;font-size:13px;">Montant</td>
              <td style="padding:8px 0;font-weight:bold;font-size:15px;color:#3A6648;">CHF ${o.price.toStringAsFixed(2)}</td></tr>
        </table>
      </td></tr>
      <tr><td style="background:#f5ece0;padding:16px 36px;font-size:12px;color:#b0a090;text-align:center;">
        Carnet · ${DateTime.now().year}
      </td></tr>
    </table>
  </td></tr>
</table></body></html>''';

    await _send(
      to: _adminEmail,
      subject: '🎉 Nouvelle commande #${o.id.substring(0, 8).toUpperCase()} — ${o.fullName}',
      html: html,
    );
  }

  // ── Email confirmation utilisateur ─────────────────────────────────────────

  static Future<void> _sendUserConfirmation(OrderModel o) async {
    final html = '''
<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8"/></head>
<body style="margin:0;padding:0;background:#f5ece0;font-family:Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="padding:40px 0;">
  <tr><td align="center">
    <table width="520" cellpadding="0" cellspacing="0"
           style="background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
      <tr><td style="background:#3A6648;padding:28px 36px;">
        <p style="margin:0;font-size:22px;font-weight:bold;color:#FFF8E8;font-style:italic;">carnet</p>
        <p style="margin:6px 0 0;color:rgba(255,248,232,.8);font-size:13px;">Votre commande est confirmée ✓</p>
      </td></tr>
      <tr><td style="padding:28px 36px;">
        <p style="margin:0 0 20px;font-size:16px;color:#2d2d2d;">Bonjour ${o.firstName},</p>
        <p style="margin:0 0 24px;font-size:15px;color:#2d2d2d;line-height:1.6;">
          Merci pour votre commande ! Nous avons bien reçu votre livre <strong>« ${o.bookTitle} »</strong>
          et nous allons le traiter dans les plus brefs délais.
        </p>
        <table width="100%" style="background:#f5ece0;border-radius:12px;margin-bottom:24px;">
          <tr><td style="padding:20px 24px;">
            <p style="margin:0 0 12px;font-size:13px;color:#7a6a5a;text-transform:uppercase;letter-spacing:1px;">Récapitulatif</p>
            <p style="margin:0 0 6px;font-size:14px;color:#2d2d2d;">📖 ${o.bookTitle}</p>
            <p style="margin:0 0 6px;font-size:14px;color:#2d2d2d;">📦 Couverture ${o.coverType == 'hard' ? 'rigide' : 'souple'}</p>
            <p style="margin:0 0 6px;font-size:14px;color:#2d2d2d;">📍 ${o.fullAddress}</p>
            <p style="margin:0;font-size:15px;font-weight:bold;color:#3A6648;">CHF ${o.price.toStringAsFixed(2)} — paiement à réception</p>
          </td></tr>
        </table>
        <p style="margin:0;font-size:14px;color:#888;line-height:1.6;">
          Vous recevrez une facture avec les détails de paiement dès que votre livre sera prêt à être envoyé.
          Délai estimé : 5 à 7 jours ouvrés.
        </p>
      </td></tr>
      <tr><td style="background:#f5ece0;padding:16px 36px;font-size:12px;color:#b0a090;text-align:center;">
        Carnet · noreply@dmathys.dev
      </td></tr>
    </table>
  </td></tr>
</table></body></html>''';

    await _send(
      to: o.userEmail,
      subject: 'Commande confirmée — ${o.bookTitle}',
      html: html,
    );
  }

  static Future<void> _send({
    required String to,
    required String subject,
    required String html,
  }) async {
    try {
      await http.post(
        Uri.parse(_resendUrl),
        headers: {
          'Authorization': 'Bearer ${AppConfig.resendApiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'from': _fromEmail, 'to': [to], 'subject': subject, 'html': html}),
      ).timeout(const Duration(seconds: 15));
    } catch (_) {}
  }
}

extension _OrderCopyWith on OrderModel {
  OrderModel copyWith({String? id}) => OrderModel(
    id: id ?? this.id,
    userId: userId,
    userEmail: userEmail,
    bookTitle: bookTitle,
    coverType: coverType,
    price: price,
    firstName: firstName,
    lastName: lastName,
    street: street,
    city: city,
    npa: npa,
    country: country,
    status: status,
    createdAt: createdAt,
    updatedAt: updatedAt,
    notebookId: notebookId,
    adminNote: adminNote,
    memoryCount: memoryCount,
    pdfUrl: pdfUrl,
  );
}
