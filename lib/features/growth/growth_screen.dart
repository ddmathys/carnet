import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/tag_service.dart';
import 'growth_tabs.dart';


/// Écran Croissance / Suivi, branché sur un TAG.
/// - Tag « enfant » (il porte une date de naissance) : courbe OMS (taille +
///   poids) + toise visuelle.
/// - Autre tag : courbe de poids simple (suivi), sans percentiles.
/// Les mesures sont des `memories` de type `taille_poids` portant ce tag.
class GrowthScreen extends StatefulWidget {
  final String tagId;
  /// Ouvre directement la saisie d'une mesure au chargement.
  final bool startAddMeasure;
  const GrowthScreen({
    super.key,
    required this.tagId,
    this.startAddMeasure = false,
  });

  @override
  State<GrowthScreen> createState() => _GrowthScreenState();
}

class _GrowthScreenState extends State<GrowthScreen> {
  bool _autoOpened = false;

  void _openMeasureSheet(NotebookModel notebook) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          MeasureSheet(notebook: notebook, previousMeasures: const []),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TagModel?>(
      future: TagService.byId(widget.tagId),
      builder: (context, tagSnap) {
        if (!tagSnap.hasData && tagSnap.connectionState != ConnectionState.done) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final tag = tagSnap.data;
        if (tag == null) {
          return const Scaffold(body: Center(child: Text('Tag introuvable.')));
        }
        // Les écrans de courbes sont écrits pour un carnet : le tag leur en
        // fournit un (titre, couleur, date de naissance) sans rien persister.
        final notebook = tag.asNotebook();
        final isChild = tag.isChild && tag.birthdate != null;
        final name = tag.label;

        final body = StreamBuilder<List<MemoryModel>>(
          stream: MemoryQueryService.visibleWithTag(widget.tagId),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final measures = snap.data!
                .where((m) => m.type == 'taille_poids')
                .where((m) => m.heightCm != null || m.weightKg != null)
                .toList()
              ..sort((a, b) => a.date.compareTo(b.date));

            if (measures.isEmpty) {
              return EmptyState(notebook: notebook, isChild: isChild);
            }

            if (!isChild) {
              // Suivi adulte : courbe de poids simple + historique + saisie.
              return AdultWeightTab(notebook: notebook, measures: measures);
            }

            return CurvesTab(notebook: notebook, measures: measures);
          },
        );

        // Ouverture auto de la saisie de mesure (depuis le menu « + » du carnet).
        if (widget.startAddMeasure && !_autoOpened) {
          _autoOpened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openMeasureSheet(notebook);
          });
        }

        return Scaffold(
          backgroundColor: AppColors.cream,
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openMeasureSheet(notebook),
            backgroundColor: AppColors.sage,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add),
            label: const Text('Nouvelle mesure'),
          ),
          appBar: AppBar(
            backgroundColor: AppColors.cream,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.pop(),
            ),
            title: Text(isChild ? 'Croissance de $name' : 'Suivi du poids'),
          ),
          body: body,
        );
      },
    );
  }
}

