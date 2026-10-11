import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/services/backend_client.dart';

/// Tableau de bord de suivi (admin).
///
/// Posé le 11.10.26, en même temps que la mesure d'usage
/// (`analytics_service.dart`), pour pouvoir lancer la communication sans
/// dépenser à l'aveugle.
///
/// ── Pourquoi cet écran EN PLUS de la console Firebase ────────────────────
/// Firebase Analytics répond à « d'où viennent les gens et où s'arrêtent-ils »
/// (entonnoir, écrans vus, canal d'acquisition), mais il est échantillonné,
/// différé de quelques heures, et son `order_paid` sous-compte par
/// construction — le paiement se joue dans le navigateur, hors de l'app.
/// Cet écran-ci répond à « combien d'argent est réellement rentré », en lisant
/// les commandes passées à « payé » par le webhook Stripe. Les deux sont
/// complémentaires : les chiffres ci-dessous sont la vérité comptable.
///
/// Les agrégats viennent du backend (`/api/notify/stats`) et pas de Firestore
/// en direct : les règles interdisent — à raison — de lister `users` ou
/// `memories` depuis un client, et un `count()` côté serveur ne facture pas
/// une lecture par document.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  Map<String, dynamic>? _stats;
  bool _loading = true;
  String? _error;

  bool get _isAdmin =>
      FirebaseAuth.instance.currentUser?.email == AppConfig.adminEmail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // `postJson` plutôt qu'un GET : c'est le seul verbe du client backend, et
      // il porte déjà le token Firebase dont l'endpoint a besoin.
      final data = await BackendClient.postJson(
        '/api/notify/stats',
        const {},
        timeout: const Duration(seconds: 30),
      );
      if (!mounted) return;
      if (data == null || data['ok'] != true) {
        setState(() {
          _loading = false;
          _error = 'Chiffres indisponibles pour le moment.';
        });
        return;
      }
      setState(() {
        _stats = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Erreur : $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAdmin) {
      return const Scaffold(body: Center(child: Text('Accès refusé')));
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.sageDark,
        elevation: 0,
        title: const Text(
          'Suivi',
          style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontWeight: FontWeight.bold,
            color: AppColors.onAccent,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.onAccent),
          onPressed: () => context.go('/profile'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.onAccent),
            tooltip: 'Rafraîchir',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 80),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMedium, fontSize: 15),
          ),
          const SizedBox(height: 20),
          Center(
            child: FilledButton(
              onPressed: _load,
              child: const Text('Réessayer'),
            ),
          ),
        ],
      );
    }

    final s = _stats!;
    final signups = (s['signups'] as Map).cast<String, dynamic>();
    final memories = (s['memories'] as Map).cast<String, dynamic>();
    final funnel = (s['funnel'] as Map).cast<String, dynamic>();
    final revenue = (s['revenue'] as Map).cast<String, dynamic>();
    final byProduct = (s['byProduct'] as Map).cast<String, dynamic>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        // ── L'argent d'abord : c'est la seule ligne qui dit si l'affaire
        //    tient debout. La marge vaut la moitié du prix de vente par
        //    construction du catalogue (book_pricing.dart::marginShare).
        _section('Argent encaissé'),
        _bigCard(
          label: 'Chiffre d\'affaires',
          value: '${_money(revenue['total'])} CHF',
          sub: 'dont ${_money(revenue['marginTotal'])} CHF de marge brute',
        ),
        Row(children: [
          Expanded(
            child: _tile(
              '30 derniers jours',
              '${_money(revenue['last30'])} CHF',
              sub: '${_money(revenue['margin30'])} de marge',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _tile(
              'Panier moyen',
              '${_money(revenue['averageOrder'])} CHF',
            ),
          ),
        ]),

        // ── L'entonnoir : à chaque étape, combien de gens restent.
        _section('Entonnoir'),
        _funnelRow(
          'Inscriptions',
          '${signups['total']}',
          'dont ${signups['last30']} sur 30 jours',
        ),
        _funnelRow(
          'Souvenirs créés',
          '${memories['total']}',
          'dont ${memories['last30']} sur 30 jours',
        ),
        _funnelRow(
          'Produits commencés',
          '${funnel['drafts']}',
          'brouillons de livre ou de puzzle jamais commandés',
          highlight: true,
        ),
        _funnelRow(
          'Commandes payées',
          '${funnel['paidTotal']}',
          '${funnel['paid30']} sur 30 jours · '
              '${funnel['ordersPending']} en attente de paiement',
        ),
        const SizedBox(height: 6),
        _bigCard(
          label: 'Taux de conversion',
          value: '${funnel['conversionPct']} %',
          sub: 'des inscrits ont déjà payé une commande',
        ),

        // ── Ventilation produit : quel produit porte réellement le revenu,
        //    donc lequel mettre en avant dans la communication.
        if (byProduct.isNotEmpty) ...[
          _section('Par produit'),
          ...byProduct.entries.map((e) {
            final v = (e.value as Map).cast<String, dynamic>();
            return _funnelRow(
              _productLabel(e.key),
              '${v['count']}',
              '${_money(v['revenue'])} CHF encaissés',
            );
          }),
        ],

        // ── Ce que cet écran ne sait PAS dire, pour ne pas le chercher ici.
        _section('À lire ailleurs'),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.cream,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            'D\'où viennent les gens, quels écrans ils voient et où ils '
            'abandonnent : console Firebase → Analytics. Les chiffres '
            'ci-dessus, eux, sont les commandes réellement payées — '
            'Analytics sous-compte les paiements, qui se font dans le '
            'navigateur hors de l\'app.',
            style: TextStyle(
              color: AppColors.textMedium,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
        if (_stats?['generatedAt'] != null) ...[
          const SizedBox(height: 14),
          Text(
            'Arrêté au ${_timestamp(_stats!['generatedAt'] as String)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMedium, fontSize: 11),
          ),
        ],
      ],
    );
  }

  // ── Briques d'affichage ────────────────────────────────────────────────────

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Text(
          title,
          style: const TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
      );

  Widget _bigCard({
    required String label,
    required String value,
    String? sub,
  }) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.sageDark,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.onAccent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                color: AppColors.onAccent,
                fontSize: 30,
                fontWeight: FontWeight.bold,
                fontFamily: 'PlayfairDisplay',
              ),
            ),
            if (sub != null) ...[
              const SizedBox(height: 4),
              Text(
                sub,
                style: const TextStyle(
                  color: AppColors.onAccent,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      );

  Widget _tile(String label, String value, {String? sub}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textMedium,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                color: AppColors.textDark,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (sub != null) ...[
              const SizedBox(height: 2),
              Text(
                sub,
                style: const TextStyle(
                  color: AppColors.textMedium,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      );

  /// Une étape d'entonnoir. [highlight] marque les brouillons : ce n'est pas
  /// une perte mais la cible exacte d'une relance.
  Widget _funnelRow(
    String label,
    String value,
    String sub, {
    bool highlight = false,
  }) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.circular(12),
          border: highlight
              ? Border.all(color: AppColors.sage.withValues(alpha: 0.5))
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.textDark,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    sub,
                    style: const TextStyle(
                      color: AppColors.textMedium,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: const TextStyle(
                color: AppColors.textDark,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                fontFamily: 'PlayfairDisplay',
              ),
            ),
          ],
        ),
      );

  // ── Formatage ──────────────────────────────────────────────────────────────

  String _money(dynamic v) {
    final d = v is num ? v.toDouble() : 0.0;
    return d.toStringAsFixed(2);
  }

  String _productLabel(String key) => switch (key) {
        'book' => 'Livres',
        'poster' => 'Tirages',
        'puzzle' => 'Puzzles',
        _ => key,
      };

  String _timestamp(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day}.${d.month}.${d.year} à ${hh}h$mm';
  }
}
