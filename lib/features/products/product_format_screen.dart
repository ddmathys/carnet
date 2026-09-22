import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';

/// Choix du format avant de composer un souvenir imprimé — point d'entrée
/// unique (remplace les anciens CTA "Créer un livre" / "Créer un tirage"
/// séparés du dashboard, deux boutons pour un seul geste — retour de David
/// le 22.09.26 : "je veux qu'un bouton et après voir la liste des produits").
///
/// « Livre » et « Poster » sont fonctionnels aujourd'hui. Calendrier/Puzzle/
/// Mural n'ont pas encore de SKU Prodigi configuré (aucun produit créé côté
/// dashboard Prodigi), donc affichés en aperçu « Bientôt disponible », non
/// cliquables — pour ne jamais laisser quelqu'un payer une commande qu'on ne
/// peut pas encore envoyer à l'impression.
class ProductFormatScreen extends StatelessWidget {
  const ProductFormatScreen({super.key});

  /// Choisir les souvenirs (écran /memories réutilisé en mode sélection,
  /// avec ses filtres) puis foncer dans le parcours livre existant
  /// (book_generate_screen.dart, inchangé : couverture, prix, adresse,
  /// commande). Rien de nouveau à réinventer là.
  Future<void> _startLivre(BuildContext context) async {
    final ids = await context.push<List<String>>(
      '/memories?select=1',
    );
    if (ids == null || ids.isEmpty || !context.mounted) return;
    context.push('/book/new?memories=${ids.join(',')}');
  }

  void _comingSoon(BuildContext context, String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label arrive bientôt !')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () => context.pop(),
        ),
        title: const Text(
          'Créer un souvenir imprimé',
          style: TextStyle(
            fontFamily: 'Fraunces',
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w600,
            color: AppColors.textDark,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          const Text(
            'Choisis un format pour commencer.',
            style: TextStyle(fontSize: 13.5, color: AppColors.textMedium),
          ),
          const SizedBox(height: 18),
          _FormatCard(
            icon: Icons.menu_book_outlined,
            iconColor: AppColors.sageDark,
            title: 'Livre',
            subtitle: 'Ton carnet en version papier, page après page.',
            priceLabel: 'dès 29 CHF',
            onTap: () => _startLivre(context),
          ),
          const SizedBox(height: 12),
          _FormatCard(
            icon: Icons.crop_original,
            iconColor: AppColors.success,
            title: 'Poster',
            subtitle: 'Une ou plusieurs photos, prêtes à accrocher.',
            priceLabel: 'dès 31 CHF',
            onTap: () => context.push('/poster/select'),
          ),
          const SizedBox(height: 12),
          _FormatCard(
            icon: Icons.calendar_month_outlined,
            iconColor: AppColors.earth,
            title: 'Calendrier',
            subtitle: 'Une photo par mois, à accrocher toute l\'année.',
            comingSoon: true,
            onTap: () => _comingSoon(context, 'Le calendrier'),
          ),
          const SizedBox(height: 12),
          _FormatCard(
            icon: Icons.extension_outlined,
            iconColor: AppColors.success,
            title: 'Puzzle',
            subtitle: 'Ton souvenir préféré, à reconstituer en famille.',
            comingSoon: true,
            onTap: () => _comingSoon(context, 'Le puzzle'),
          ),
          const SizedBox(height: 12),
          _FormatCard(
            icon: Icons.image_outlined,
            iconColor: AppColors.coverBlue,
            title: 'Mural',
            subtitle: 'Une photo à afficher en grand, sur ton mur.',
            comingSoon: true,
            onTap: () => _comingSoon(context, 'Le mural'),
          ),
        ],
      ),
    );
  }
}

class _FormatCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String? priceLabel;
  final bool comingSoon;
  final VoidCallback onTap;

  const _FormatCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.priceLabel,
    this.comingSoon = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: comingSoon ? 0.6 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDark)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textMedium, height: 1.3)),
                    const SizedBox(height: 5),
                    if (comingSoon)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.softGray.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: const Text('Bientôt disponible',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.softGray)),
                      )
                    else if (priceLabel != null)
                      Text(priceLabel!,
                          style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.earth)),
                  ],
                ),
              ),
              if (!comingSoon)
                const Icon(Icons.chevron_right, color: AppColors.softGray),
            ],
          ),
        ),
      ),
    );
  }
}
