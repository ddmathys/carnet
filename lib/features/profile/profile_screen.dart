import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/services/backend_client.dart';
import '../../core/services/book_pricing.dart';
import '../../core/services/notification_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _nameController = TextEditingController();
  bool _editing = false;
  bool _saving = false;
  String? _error;
  bool _deletingAccount = false;

  // Notifications « souvenir du jour ».
  NotifyFrequency _notifyFrequency = NotifyFrequency.none;
  bool _notifyLoading = true;
  bool _sendingTest = false;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    _nameController.text = user?.displayName ?? '';
    _loadNotifyFrequency();
  }

  Future<void> _loadNotifyFrequency() async {
    final frequency = await NotificationService.currentFrequency();
    if (!mounted) return;
    setState(() {
      _notifyFrequency = frequency;
      _notifyLoading = false;
    });
  }

  /// Changement de fréquence. Si l'autorisation système est refusée, le réglage
  /// NE bascule PAS : afficher « chaque jour » alors qu'aucune notification ne
  /// peut arriver serait un mensonge à l'écran.
  Future<void> _setNotifyFrequency(NotifyFrequency frequency) async {
    if (frequency == _notifyFrequency || _notifyLoading) return;
    setState(() => _notifyLoading = true);
    final ok = await NotificationService.setFrequency(frequency);
    if (!mounted) return;
    setState(() {
      if (ok) _notifyFrequency = frequency;
      _notifyLoading = false;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Notifications refusées. Autorise-les pour Carnet dans les '
            'réglages de ton téléphone, puis reviens ici.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    }
  }

  // Envoi immédiat, pour vérifier tout de suite plutôt que d'attendre le
  // cron quotidien (7h UTC) — surtout utile juste après avoir activé les
  // notifications, ou après une mise à jour du backend.
  Future<void> _sendTestNow() async {
    if (_sendingTest) return;
    setState(() => _sendingTest = true);
    try {
      await NotificationService.sendNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notification envoyée — regarde ton téléphone.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingTest = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() { _saving = true; _error = null; });
    try {
      await FirebaseAuth.instance.currentUser!.updateDisplayName(name);
      if (mounted) setState(() { _editing = false; });
    } catch (_) {
      if (mounted) setState(() => _error = 'Impossible de sauvegarder.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signOut() async {
    // Avant le signOut, tant qu'on connaît encore l'uid : cet appareil ne doit
    // plus recevoir les souvenirs du compte qu'on quitte.
    await NotificationService.forgetDevice();
    await FirebaseAuth.instance.signOut();
    if (mounted) context.go('/auth');
  }

  // Suppression DÉFINITIVE du compte et de toutes les données (souvenirs,
  // médias, carnets, tags possédés) — voir backend/api/notebook/[action].ts
  // (action delete-account) pour le détail exact de ce qui est effacé. Seule
  // exception : les commandes déjà payées sont anonymisées, pas supprimées
  // (obligations comptables), comme documenté sur dmathys.dev/delete-account.html.
  Future<void> _confirmDeleteAccount() async {
    var understood = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Supprimer définitivement ton compte ?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cette action est IRRÉVERSIBLE. Seront supprimés sans '
                'exception : tous tes souvenirs (photos, vidéos, mémos '
                'vocaux), les mesures de croissance, tes carnets et tags, '
                'ton profil et ton compte de connexion.\n\n'
                'Exception : les commandes déjà payées sont conservées de '
                'façon anonyme (prix, date) pour nos obligations comptables '
                '— tes photos et coordonnées en sont retirées.',
                style: TextStyle(color: AppColors.textMedium, height: 1.5),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: () =>
                    setDialogState(() => understood = !understood),
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: understood,
                      activeColor: AppColors.error,
                      onChanged: (v) =>
                          setDialogState(() => understood = v ?? false),
                    ),
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text(
                          'J\'ai compris, tout sera supprimé définitivement.',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textDark),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler',
                  style: TextStyle(color: AppColors.textMedium)),
            ),
            ElevatedButton(
              onPressed: understood ? () => Navigator.pop(ctx, true) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                disabledBackgroundColor: AppColors.error.withOpacity(0.35),
              ),
              child: const Text('Supprimer définitivement'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) await _deleteAccount();
  }

  Future<void> _deleteAccount() async {
    setState(() => _deletingAccount = true);
    final result = await BackendClient.postJson(
      '/api/notebook/delete-account',
      const {},
      timeout: const Duration(seconds: 55),
    );
    if (!mounted) return;
    if (result == null) {
      setState(() => _deletingAccount = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Échec de la suppression — vérifie ta connexion et réessaie.'),
        ),
      );
      return;
    }
    // Le compte Firebase Auth a déjà été supprimé côté serveur ; on nettoie
    // juste la session locale avant de renvoyer vers l'écran de connexion.
    await NotificationService.forgetDevice();
    await FirebaseAuth.instance.signOut();
    if (mounted) context.go('/auth');
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    final isEmailProvider = user.providerData.any((p) => p.providerId == 'password');

    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: AppBar(
        backgroundColor: AppColors.cream,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Mon profil'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // En-tête profil : avatar corail à initiale + nom + email
            Center(
              child: Column(
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                        color: AppColors.sageDark, shape: BoxShape.circle),
                    child: Text(
                      (user.displayName?.isNotEmpty == true
                              ? user.displayName!
                              : (user.email ?? '?'))[0]
                          .toUpperCase(),
                      style: const TextStyle(
                        fontFamily: 'Fraunces',
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    user.displayName?.isNotEmpty == true
                        ? user.displayName!
                        : 'Bienvenue',
                    style: const TextStyle(
                      fontFamily: 'Fraunces',
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark,
                    ),
                  ),
                  if (user.email != null)
                    Text(user.email!,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textMedium)),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // Name section
            _SectionLabel(label: 'Prénom / Nom'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _editing
                      ? TextField(
                          controller: _nameController,
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: 'Votre prénom',
                          ),
                          onSubmitted: (_) => _saveName(),
                        )
                      : Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            user.displayName?.isNotEmpty == true
                                ? user.displayName!
                                : 'Non renseigné',
                            style: TextStyle(
                              fontSize: 15,
                              color: user.displayName?.isNotEmpty == true
                                  ? AppColors.textDark
                                  : AppColors.softGray,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                if (_editing)
                  _saving
                      ? const SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          onPressed: _saveName,
                          icon: const Icon(Icons.check),
                          color: AppColors.sage,
                        )
                else
                  IconButton(
                    onPressed: () => setState(() => _editing = true),
                    icon: const Icon(Icons.edit_outlined),
                    color: AppColors.sage,
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 12)),
            ],
            const SizedBox(height: 20),

            // Email section
            _SectionLabel(label: 'Email'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.email_outlined, size: 18, color: AppColors.softGray),
                  const SizedBox(width: 10),
                  Text(
                    user.email ?? '—',
                    style: const TextStyle(fontSize: 15, color: AppColors.textDark),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // Notifications « souvenir du jour »
            _SectionLabel(label: 'Souvenir du jour'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome_outlined,
                          size: 18, color: AppColors.sage),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Une photo de ton carnet, ressortie au hasard.',
                          style: TextStyle(
                              fontSize: 13.5, color: AppColors.textDark),
                        ),
                      ),
                      if (_notifyLoading)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (final frequency in NotifyFrequency.values)
                    _FrequencyOption(
                      label: frequency.label,
                      selected: frequency == _notifyFrequency,
                      onTap: _notifyLoading
                          ? null
                          : () => _setNotifyFrequency(frequency),
                    ),
                  if (_notifyFrequency != NotifyFrequency.none) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _sendingTest ? null : _sendTestNow,
                        icon: _sendingTest
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send_outlined, size: 16),
                        label: const Text('Envoyer maintenant (test)'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Mes commandes
            _ProfileTile(
              icon: Icons.local_shipping_outlined,
              label: 'Mes commandes',
              onTap: () => context.push('/orders'),
            ),
            const SizedBox(height: 8),

            // Tarifs d'impression (transparence)
            _ProfileTile(
              icon: Icons.receipt_long_outlined,
              label: 'Tarifs d\'impression',
              onTap: () => _showPricingSheet(context),
            ),
            const SizedBox(height: 8),

            // Admin (visible uniquement pour david.mathys24@gmail.com)
            if (user.email == AppConfig.adminEmail) ...[
              _ProfileTile(
                icon: Icons.admin_panel_settings_outlined,
                label: 'Console admin',
                color: AppColors.sageDark,
                onTap: () => context.push('/admin/orders'),
              ),
              const SizedBox(height: 8),
            ],

            // Divider
            Divider(color: AppColors.border),
            const SizedBox(height: 16),

            // Sign out
            OutlinedButton.icon(
              onPressed: _signOut,
              icon: const Icon(Icons.logout_outlined, size: 18),
              label: const Text('Se déconnecter'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textMedium,
                side: BorderSide(color: AppColors.border),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            if (isEmailProvider) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _showChangePasswordDialog(context, user.email!),
                child: const Text(
                  'Changer mon mot de passe',
                  style: TextStyle(color: AppColors.sage),
                ),
              ),
            ] else if (user.email != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _showAddPasswordDialog(context, user.email!),
                child: const Text(
                  'Ajouter un mot de passe',
                  style: TextStyle(color: AppColors.sage),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _deletingAccount ? null : _confirmDeleteAccount,
              icon: _deletingAccount
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.error),
                    )
                  : const Icon(Icons.delete_forever_outlined,
                      size: 18, color: AppColors.error),
              label: Text(
                _deletingAccount
                    ? 'Suppression en cours…'
                    : 'Supprimer mon compte',
                style: const TextStyle(color: AppColors.error),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Tableau de transparence des coûts d'impression (souple / rigide × pages).
  // Affiche tes prix réels, sans comparaison concurrents.
  void _showPricingSheet(BuildContext context) {
    const samples = [30, 40, 60, 80, 100, 150, 200];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.softGray.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Tarifs d\'impression',
                style: TextStyle(
                  fontFamily: 'PlayfairDisplay',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Prix tout compris : impression + livraison en Suisse + TVA. '
                'Il dépend de la couverture (souple / rigide) et du nombre de '
                'pages. Les livres imprimés font 28 pages minimum.',
                style: TextStyle(
                    color: AppColors.textMedium, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              // En-tête du tableau
              Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                decoration: BoxDecoration(
                  color: AppColors.cream,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Expanded(
                        flex: 2,
                        child: Text('Pages',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: AppColors.textDark))),
                    Expanded(
                        flex: 3,
                        child: Text('Souple',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: AppColors.textDark))),
                    Expanded(
                        flex: 3,
                        child: Text('Rigide',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: AppColors.textDark))),
                  ],
                ),
              ),
              for (final p in samples)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          '$p',
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textDark,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          BookPricing.format(
                              BookPricing.price(coverType: 'soft', pages: p)),
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textMedium),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          BookPricing.format(
                              BookPricing.price(coverType: 'hard', pages: p)),
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textMedium),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.sage.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.sage.withOpacity(0.25)),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.verified_outlined, size: 16, color: AppColors.sage),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Le PDF numérique est toujours gratuit. Pour l\'imprimé, '
                        'tu paies uniquement le prix ci-dessus — sans abonnement '
                        'ni frais cachés.',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMedium,
                            height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context, String email) {
    _showPasswordEmailDialog(
      context,
      email: email,
      title: 'Réinitialiser le mot de passe',
    );
  }

  /// Compte connecté uniquement via Google : aucun mot de passe n'existe sur
  /// ce compte, donc "Se connecter" avec un mot de passe échoue toujours,
  /// sans que rien dans le profil ne l'explique ni ne propose d'y remédier
  /// (trouvé à l'audit UX du 03.09.26). Réutilise le même envoi — le lien de
  /// réinitialisation Firebase fonctionne aussi bien pour AJOUTER un premier
  /// mot de passe à un compte qui n'en a pas.
  void _showAddPasswordDialog(BuildContext context, String email) {
    _showPasswordEmailDialog(
      context,
      email: email,
      title: 'Ajouter un mot de passe',
      body: 'Ton compte est connecté uniquement via Google. Un email te '
          'permettra de définir un mot de passe, pour pouvoir aussi te '
          'connecter avec.',
    );
  }

  void _showPasswordEmailDialog(
    BuildContext context, {
    required String email,
    required String title,
    String? body,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title),
        content: Text(
          body ?? 'Un email de réinitialisation sera envoyé à $email.',
          style: const TextStyle(color: AppColors.textMedium, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler',
                style: TextStyle(color: AppColors.textMedium)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              // Passe par le backend (Resend) plutôt que
              // FirebaseAuth.sendPasswordResetEmail : le relai email par
              // défaut de Firebase Auth n'arrivait pas chez David (03.09.26) —
              // même fix que auth_screen.dart, ce dialogue utilisait encore
              // l'ancien chemin.
              final data = await BackendClient.postJson(
                '/api/notify/reset-password',
                {'email': email},
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(data?['ok'] == true
                        ? 'Email envoyé ! Vérifie ta boîte mail.'
                        : 'Une erreur est survenue. Réessaie.'),
                    backgroundColor:
                        data?['ok'] == true ? AppColors.sage : AppColors.error,
                  ),
                );
              }
            },
            child: const Text('Envoyer'),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.softGray,
          letterSpacing: 0.5),
    );
  }
}

/// Une ligne du choix de fréquence. Écrit à la main plutôt qu'avec
/// `RadioListTile` : l'API `groupValue` des Radio est dépréciée côté Flutter
/// récent, et ça colle mieux au reste de l'écran, entièrement en conteneurs
/// maison.
class _FrequencyOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  const _FrequencyOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.sageDark : AppColors.textMedium;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected ? AppColors.sage : AppColors.softGray,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;
  const _ProfileTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = AppColors.sage,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
              style: TextStyle(fontSize: 15, color: color, fontWeight: FontWeight.w500)),
          ),
          Icon(Icons.chevron_right, size: 18, color: AppColors.softGray),
        ],
      ),
    ),
  );
}
