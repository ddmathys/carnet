import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';

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

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    _nameController.text = user?.displayName ?? '';
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
            // Avatar
            Center(
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.sage.withOpacity(0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.sage.withOpacity(0.3), width: 2),
                ),
                child: const Icon(Icons.person, size: 40, color: AppColors.sage),
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
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Text(
                            user.displayName?.isNotEmpty == true
                                ? user.displayName!
                                : 'Non renseigné',
                            style: TextStyle(
                              fontSize: 15,
                              color: user.displayName?.isNotEmpty == true
                                  ? AppColors.textDark
                                  : Colors.grey.shade400,
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
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
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
            const SizedBox(height: 32),

            // Mes commandes
            _ProfileTile(
              icon: Icons.local_shipping_outlined,
              label: 'Mes commandes',
              onTap: () => context.push('/orders'),
            ),
            const SizedBox(height: 8),

            // Admin (visible uniquement pour david.mathys24@gmail.com)
            if (user.email == 'david.mathys24@gmail.com') ...[
              _ProfileTile(
                icon: Icons.admin_panel_settings_outlined,
                label: 'Console admin',
                color: AppColors.sageDark,
                onTap: () => context.push('/admin/orders'),
              ),
              const SizedBox(height: 8),
            ],

            // Divider
            Divider(color: Colors.grey.shade200),
            const SizedBox(height: 16),

            // Sign out
            OutlinedButton.icon(
              onPressed: _signOut,
              icon: const Icon(Icons.logout_outlined, size: 18),
              label: const Text('Se déconnecter'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textMedium,
                side: BorderSide(color: Colors.grey.shade300),
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
            ],
          ],
        ),
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context, String email) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Réinitialiser le mot de passe'),
        content: Text(
          'Un email de réinitialisation sera envoyé à $email.',
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
              await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Email envoyé ! Vérifie ta boîte mail.'),
                    backgroundColor: AppColors.sage,
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
          color: Colors.grey.shade500,
          letterSpacing: 0.5),
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
              style: TextStyle(fontSize: 15, color: color, fontWeight: FontWeight.w500)),
          ),
          Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade400),
        ],
      ),
    ),
  );
}
