import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/user_service.dart';

/// Console admin — gestion des utilisateurs et du palier Premium.
/// Réservé à l'admin (route protégée côté navigation ; l'écriture du tier est
/// autorisée par firestore.rules `isAdmin()`).
class AdminUsersScreen extends StatelessWidget {
  const AdminUsersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('Utilisateurs',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
      ),
      body: StreamBuilder<List<AppUser>>(
        stream: UserService.allUsersStream(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(child: Text('Erreur de chargement.'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final users = snap.data!;
          if (users.isEmpty) {
            return const Center(child: Text('Aucun utilisateur.'));
          }
          final requested = users.where((u) => u.premiumRequested && !u.isPremium).length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              if (requested > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '$requested demande${requested > 1 ? 's' : ''} Premium en attente',
                    style: const TextStyle(
                        color: AppColors.amber, fontWeight: FontWeight.w700),
                  ),
                ),
              ...users.map((u) => _UserCard(user: u)),
            ],
          );
        },
      ),
    );
  }
}

class _UserCard extends StatefulWidget {
  final AppUser user;
  const _UserCard({required this.user});

  @override
  State<_UserCard> createState() => _UserCardState();
}

class _UserCardState extends State<_UserCard> {
  bool _busy = false;

  Future<void> _setTier(String tier) async {
    setState(() => _busy = true);
    try {
      await UserService.setSubscriptionTier(widget.user.uid, tier);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tier == 'premium'
              ? 'Premium activé pour ${widget.user.email}'
              : 'Repassé en gratuit : ${widget.user.email}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: u.premiumRequested && !u.isPremium
              ? AppColors.amber.withOpacity(0.5)
              : const AppColors.border,
          width: u.premiumRequested && !u.isPremium ? 1.2 : 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      u.displayName.isNotEmpty ? u.displayName : u.email,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: AppColors.textDark),
                    ),
                    if (u.displayName.isNotEmpty)
                      Text(u.email,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.softGray)),
                  ],
                ),
              ),
              _TierBadge(isPremium: u.isPremium),
            ],
          ),
          if (u.premiumRequested && !u.isPremium) ...[
            const SizedBox(height: 6),
            const Text('🟠 A demandé Premium',
                style: TextStyle(fontSize: 12, color: AppColors.amber)),
          ],
          const SizedBox(height: 12),
          if (_busy)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(4),
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else if (u.isPremium)
            OutlinedButton.icon(
              onPressed: () => _setTier('free'),
              icon: const Icon(Icons.lock_outline, size: 16),
              label: const Text('Bloquer (repasser gratuit)'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textMedium,
                side: const BorderSide(color: AppColors.border),
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: () => _setTier('premium'),
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Paiement OK · Activer Premium'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.sage,
                foregroundColor: Colors.white,
              ),
            ),
        ],
      ),
    );
  }
}

class _TierBadge extends StatelessWidget {
  final bool isPremium;
  const _TierBadge({required this.isPremium});

  @override
  Widget build(BuildContext context) {
    final c = isPremium ? AppColors.sage : AppColors.softGray;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isPremium ? '★ Premium' : 'Gratuit',
        style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}
