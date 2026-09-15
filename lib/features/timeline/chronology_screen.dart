import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/memory_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/theme/app_theme.dart';

/// Tes années, racontées par les lieux visités — demande de David (15.09.26),
/// validée sur maquette avant implémentation :
/// https://claude.ai/artifact/XsVfDwUCSFxq1qAVQxAKWX
///
/// Calculé 100% côté client depuis les souvenirs déjà visibles (comme
/// features/retro) : pas d'appel réseau dédié. Groupe par année (date du
/// souvenir) puis par lieu (`memory.location`, variantes de casse fusionnées
/// — « Genève »/« Geneve » comptent ensemble, affichées sous la graphie la
/// plus fréquente).
class ChronologyScreen extends StatelessWidget {
  const ChronologyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Chronologie des lieux',
          style: TextStyle(
              fontFamily: 'Fraunces',
              fontWeight: FontWeight.w600,
              color: AppColors.textDark),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: StreamBuilder<List<MemoryModel>>(
        stream: MemoryQueryService.visible(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final years = _YearData.build(snap.data!);
          if (years.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Aucun souvenir avec un lieu pour l\'instant — ajoute un '
                  'lieu à tes souvenirs pour les voir apparaître ici.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMedium, fontSize: 14),
                ),
              ),
            );
          }
          final totalMemories =
              years.fold<int>(0, (s, y) => s + y.total);
          final allPlaces = <String>{
            for (final y in years) for (final p in y.places) p.key,
          };

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              _StatsRow(
                totalMemories: totalMemories,
                totalPlaces: allPlaces.length,
                totalYears: years.length,
              ),
              const SizedBox(height: 8),
              for (final y in years) _YearBlock(year: y),
            ],
          );
        },
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final int totalMemories;
  final int totalPlaces;
  final int totalYears;
  const _StatsRow({
    required this.totalMemories,
    required this.totalPlaces,
    required this.totalYears,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _Stat(value: totalMemories, label: 'Souvenirs'),
          _Stat(value: totalPlaces, label: 'Lieux'),
          _Stat(value: totalYears, label: 'Années'),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final int value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('$value',
            style: const TextStyle(
              fontFamily: 'Fraunces',
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: AppColors.sageDark,
            )),
        const SizedBox(height: 2),
        Text(label.toUpperCase(),
            style: const TextStyle(
              fontSize: 9.5,
              letterSpacing: .6,
              color: AppColors.softGray,
              fontWeight: FontWeight.w600,
            )),
      ],
    );
  }
}

class _YearBlock extends StatefulWidget {
  final _YearData year;
  const _YearBlock({required this.year});

  @override
  State<_YearBlock> createState() => _YearBlockState();
}

class _YearBlockState extends State<_YearBlock> {
  String? _openPlaceKey;

  @override
  Widget build(BuildContext context) {
    final y = widget.year;
    final maxCount = y.places.first.count;
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${y.year}',
                  style: const TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 25,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark,
                  )),
              const SizedBox(width: 10),
              Text('${y.total} souvenir${y.total > 1 ? 's' : ''}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.softGray)),
              const SizedBox(width: 10),
              Expanded(
                  child: Container(height: 1, color: AppColors.border)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final p in y.places)
                _PlaceChip(
                  place: p,
                  weight: p.count / maxCount,
                  open: _openPlaceKey == p.key,
                  onTap: () => setState(
                      () => _openPlaceKey = _openPlaceKey == p.key ? null : p.key),
                  onOpen: () => context.push(
                      '/memories?year=${y.year}&loc=${Uri.encodeComponent(p.label)}'),
                ),
            ],
          ),
          if (y.total <= 2) ...[
            const SizedBox(height: 6),
            const Text(
              'Peu de souvenirs datés cette année-là.',
              style: TextStyle(
                  color: AppColors.softGray,
                  fontSize: 11,
                  fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlaceChip extends StatelessWidget {
  final _PlaceCount place;
  final double weight; // 0..1, poids relatif dans l'année
  final bool open;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  const _PlaceChip({
    required this.place,
    required this.weight,
    required this.open,
    required this.onTap,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final isTop = weight >= 0.999 && place.count > 1;
    final bg = isTop ? AppColors.sageDark : AppColors.surface;
    final fg = isTop ? AppColors.background : AppColors.textDark;
    final countFg = isTop ? AppColors.background : AppColors.sageDark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: 13, vertical: weight >= 0.4 ? 9 : 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: open ? AppColors.sageDark : AppColors.border,
                width: open ? 1.4 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(place.label,
                    style: TextStyle(
                        fontSize: weight >= 0.4 ? 12.5 : 12,
                        fontWeight: isTop ? FontWeight.w700 : FontWeight.w500,
                        color: fg)),
                const SizedBox(width: 6),
                Text('${place.count}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: countFg)),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GestureDetector(
              onTap: onOpen,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.cream,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Voir ${place.count} souvenir${place.count > 1 ? 's' : ''} à ${place.label}',
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textMedium),
                      ),
                    ),
                    const Icon(Icons.arrow_forward,
                        size: 14, color: AppColors.softGray),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Données ──────────────────────────────────────────────────────────────

class _PlaceCount {
  final String key; // normalisée (minuscule) — pour dédupliquer/trier
  final String label; // graphie la plus fréquente — pour l'affichage
  final int count;
  const _PlaceCount(this.key, this.label, this.count);
}

class _YearData {
  final int year;
  final List<_PlaceCount> places; // triés par fréquence décroissante
  final int total;
  const _YearData(this.year, this.places, this.total);

  /// Regroupe les souvenirs (hors mesures de croissance) par année puis par
  /// lieu. Les variantes de casse d'un même lieu (« Genève »/« Geneve ») sont
  /// fusionnées — sinon un lieu tapé différemment une fois compterait comme
  /// un lieu distinct, cf. l'audit du 15.09.26 sur les tags dupliqués.
  static List<_YearData> build(List<MemoryModel> memories) {
    final byYear = <int, Map<String, Map<String, int>>>{};
    for (final m in memories) {
      if (m.type == 'taille_poids') continue;
      final loc = (m.location ?? '').trim();
      if (loc.isEmpty) continue;
      final key = loc.toLowerCase();
      final year = m.date.year;
      final labels = byYear.putIfAbsent(year, () => {}).putIfAbsent(key, () => {});
      labels.update(loc, (v) => v + 1, ifAbsent: () => 1);
    }

    final out = <_YearData>[];
    byYear.forEach((year, places) {
      final placeCounts = <_PlaceCount>[];
      var total = 0;
      places.forEach((key, labelCounts) {
        final count = labelCounts.values.fold(0, (a, b) => a + b);
        // Graphie la plus fréquente pour l'affichage ; à égalité, la plus
        // longue (souvent la plus "complète", ex. accents présents).
        final bestLabel = labelCounts.entries
            .reduce((a, b) => b.value > a.value ||
                    (b.value == a.value && b.key.length > a.key.length)
                ? b
                : a)
            .key;
        placeCounts.add(_PlaceCount(key, bestLabel, count));
        total += count;
      });
      placeCounts.sort((a, b) => b.count.compareTo(a.count));
      out.add(_YearData(year, placeCounts, total));
    });
    out.sort((a, b) => b.year.compareTo(a.year));
    return out;
  }
}
