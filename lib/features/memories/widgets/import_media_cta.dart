import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

/// Bouton « Importer des médias » (créer un souvenir) — partagé entre le
/// dashboard d'accueil et les écrans carnet pour un flux d'ajout identique.
class ImportMediaCta extends StatelessWidget {
  final VoidCallback onTap;
  final EdgeInsets padding;
  const ImportMediaCta({
    super.key,
    required this.onTap,
    this.padding = const EdgeInsets.fromLTRB(22, 16, 22, 18),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.sageTint,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: AppColors.sageDark,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.sageDark.withOpacity(0.45),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(Icons.add_photo_alternate_outlined,
                    color: Colors.white, size: 30),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Importer des médias',
                        style: TextStyle(
                          fontFamily: 'Fraunces',
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark,
                        )),
                    SizedBox(height: 3),
                    Text('Crée un souvenir : photos, vidéo, audio.',
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.textMedium)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.sage),
            ],
          ),
        ),
      ),
    );
  }
}
