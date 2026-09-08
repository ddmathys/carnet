import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/tag_service.dart';
import '../tags/person_avatar.dart';
import 'retro_data.dart';

/// Écran C — Lecture de la rétrospective.
///
/// En-tête, cartes de stats, puis une timeline verticale (ligne + pastille
/// par mois) : chaque repère porte sa date, et un bandeau discret en haut de
/// la liste affiche la date du mois qu'on est en train de lire, mise à jour
/// pendant le scroll. Le texte de chaque mois est la matière réelle des
/// souvenirs (pas d'IA à ce stade).
class RetroViewScreen extends StatefulWidget {
  final RetroSubject subject;
  // Souvenirs/tags déjà chargés par l'écran de choix du sujet (qui les tient
  // à jour en temps réel) : évite un rechargement (spinner) à chaque sujet
  // ouvert. Absents seulement si l'écran est atteint autrement qu'en passant
  // par ce choix (repli sur un chargement classique).
  final List<MemoryModel>? initialMemories;
  final List<TagModel>? initialTags;

  const RetroViewScreen({
    super.key,
    required this.subject,
    this.initialMemories,
    this.initialTags,
  });

  @override
  State<RetroViewScreen> createState() => _RetroViewScreenState();
}

class _RetroViewScreenState extends State<RetroViewScreen> {
  StreamSubscription? _memSub;
  StreamSubscription? _tagSub;
  List<TagModel> _tags = [];
  List<MemoryModel> _memories = const [];
  RetroData? _data;
  bool _loading = true;

  // Suit quel mois est visible en haut de la liste, pour le bandeau de date
  // sticky (voir _onScroll).
  final _positions = ItemPositionsListener.create();
  final ValueNotifier<String?> _activeLabel = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _positions.itemPositions.addListener(_onScroll);
    final memories = widget.initialMemories;
    final tags = widget.initialTags;
    if (memories != null && tags != null) {
      // Déjà en cache (écran de choix du sujet) : affichage immédiat, pas de
      // rechargement réseau ni de spinner à chaque sujet ouvert.
      _tags = tags;
      _memories = memories;
      _data = RetroData.build(widget.subject, memories, tags);
      _loading = false;
      _primeActiveLabel();
      _listenLive();
    } else {
      // Repli (deep link direct, sans données déjà en cache) : tags suivis en
      // direct comme sur l'écran de choix du sujet.
      _tagSub = TagService.streamVisible().listen((tags) {
        _tags = tags;
        _rebuild();
      });
      _listenLive();
    }
  }

  /// Écoute les souvenirs en temps réel : la rétrospective reste à jour
  /// (nouveau souvenir tagué, média ajouté…) sans jamais avoir à revenir en
  /// arrière et rouvrir le sujet.
  void _listenLive() {
    _memSub = MemoryQueryService.visible().listen((mems) {
      _memories = mems;
      _loading = false;
      _rebuild();
    });
  }

  void _rebuild() {
    if (!mounted) return;
    setState(() => _data = RetroData.build(widget.subject, _memories, _tags));
    _primeActiveLabel();
  }

  /// Le bandeau sticky doit afficher une date dès le premier rendu, pas
  /// attendre le premier scroll pour sortir de son état vide.
  void _primeActiveLabel() {
    if (_activeLabel.value != null) return;
    final sections = _data?.sections ?? const [];
    if (sections.isNotEmpty) _activeLabel.value = sections.first.label;
  }

  void _onScroll() {
    final data = _data;
    if (data == null) return;
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty) return;
    // Premier item dont le bas est encore visible = celui « au sommet ».
    final top = positions
        .where((p) => p.itemTrailingEdge > 0)
        .fold<ItemPosition?>(null, (best, p) {
      if (best == null || p.itemLeadingEdge < best.itemLeadingEdge) return p;
      return best;
    });
    if (top == null) return;
    // Index 0 = en-tête ; les sections commencent à 1.
    final sectionIndex = top.index - 1;
    if (sectionIndex < 0 || sectionIndex >= data.sections.length) {
      _activeLabel.value =
          data.sections.isNotEmpty ? data.sections.first.label : null;
      return;
    }
    _activeLabel.value = data.sections[sectionIndex].label;
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_onScroll);
    _activeLabel.dispose();
    _memSub?.cancel();
    _tagSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        foregroundColor: AppColors.textDark,
        title: Text(
          widget.subject.label,
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontWeight: FontWeight.w600,
            color: AppColors.textDark,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (data == null || data.sections.isEmpty)
              ? const Center(
                  child: Text('Aucun souvenir à raconter.',
                      style: TextStyle(color: AppColors.textMedium)),
                )
              : Column(
                  children: [
                    // Bandeau sticky : la date du mois qu'on est en train de
                    // lire, mise à jour pendant le scroll (voir _onScroll).
                    if (data.sections.length > 1)
                      _ActiveDateBanner(activeLabel: _activeLabel),
                    Expanded(
                      child: ScrollablePositionedList.builder(
                        itemPositionsListener: _positions,
                        padding: const EdgeInsets.only(bottom: 28),
                        itemCount: data.sections.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) return _IntroHeader(data: data);
                          final i = index - 1;
                          return _SectionCard(
                            section: data.sections[i],
                            isLast: i == data.sections.length - 1,
                          );
                        },
                      ),
                    ),
                    _BookCta(
                      onTap: () => context.push('/book/select'),
                    ),
                  ],
                ),
    );
  }
}

/// En-tête + sous-titre + cartes de stats (item 0 de la liste, défile).
class _IntroHeader extends StatelessWidget {
  final RetroData data;
  const _IntroHeader({required this.data});

  @override
  Widget build(BuildContext context) {
    final s = data.subject;
    final subtitleParts = <String>[
      '${s.count} souvenirs',
      s.rangeLabel,
      if (data.placeCount > 0)
        '${data.placeCount} lieu${data.placeCount > 1 ? 'x' : ''}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PersonAvatar(
                label: s.label,
                photoKey: s.photoKey,
                colorHex: s.color,
                size: 52,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  s.label,
                  style: const TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            subtitleParts.join(' · '),
            style: const TextStyle(fontSize: 13.5, color: AppColors.textMedium),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (data.densestYear != null)
                Expanded(
                  child: _StatCard(
                    label: 'Année la plus dense',
                    value: '${data.densestYear}',
                  ),
                ),
              if (data.densestYear != null && data.topCoTagLabel != null)
                const SizedBox(width: 12),
              if (data.topCoTagLabel != null)
                Expanded(
                  child: _StatCard(
                    label: 'Souvent avec',
                    value: data.topCoTagLabel!,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.sageTint,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppColors.textMedium,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Fraunces',
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppColors.sage,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau sticky au-dessus de la liste : la date du mois qu'on est en train
/// de lire (voir _onScroll), pour toujours savoir où on en est sans avoir à
/// remonter.
class _ActiveDateBanner extends StatelessWidget {
  final ValueNotifier<String?> activeLabel;
  const _ActiveDateBanner({required this.activeLabel});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: ValueListenableBuilder<String?>(
        valueListenable: activeLabel,
        builder: (context, label, _) => Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppColors.sage,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label ?? '',
              style: const TextStyle(
                fontFamily: 'Fraunces',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Une section mensuelle, sur la ligne verticale de la timeline : sa pastille
/// et le segment de ligne qui la relie à la section suivante, sa date, un
/// texte condensé (matière réelle des souvenirs), ses photos.
class _SectionCard extends StatelessWidget {
  final RetroSection section;
  final bool isLast;
  const _SectionCard({required this.section, this.isLast = false});

  @override
  Widget build(BuildContext context) {
    final narrative = section.narrative;
    return IntrinsicHeight(
      child: Padding(
        padding: const EdgeInsets.only(left: 20, right: 20, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // La ligne verticale + la pastille de ce mois.
            SizedBox(
              width: 18,
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 5),
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      color: AppColors.sage,
                      shape: BoxShape.circle,
                    ),
                  ),
                  if (!isLast)
                    Expanded(
                      child: Container(
                        width: 1.4,
                        margin: const EdgeInsets.only(top: 5),
                        color: AppColors.border,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.label.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                        color: AppColors.sage,
                      ),
                    ),
                    if (narrative.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        narrative,
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.4,
                          color: AppColors.textDark,
                        ),
                      ),
                    ],
                    if (section.heroes.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _PhotoGrid(memories: section.heroes),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Jusqu'à 3 photos : une grande à gauche, deux empilées à droite.
class _PhotoGrid extends StatelessWidget {
  final List<MemoryModel> memories;
  const _PhotoGrid({required this.memories});

  @override
  Widget build(BuildContext context) {
    final list = memories.take(3).toList();
    if (list.length == 1) {
      return _HeroPhoto(memory: list.first, aspectRatio: 4 / 3);
    }
    if (list.length == 2) {
      return Row(
        children: [
          Expanded(child: _HeroPhoto(memory: list[0], aspectRatio: 1)),
          const SizedBox(width: 6),
          Expanded(child: _HeroPhoto(memory: list[1], aspectRatio: 1)),
        ],
      );
    }
    return SizedBox(
      height: 200,
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: _HeroPhoto(memory: list[0], fill: true),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _HeroPhoto(memory: list[1], fill: true)),
                const SizedBox(height: 6),
                Expanded(child: _HeroPhoto(memory: list[2], fill: true)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Charge et affiche la première photo d'un souvenir (URL signée R2, mise en
/// cache par PhotoService). Le futur est retenu pour éviter de re-signer à
/// chaque rebuild de la liste.
class _HeroPhoto extends StatefulWidget {
  final MemoryModel memory;
  final double? aspectRatio;
  final bool fill;
  const _HeroPhoto({
    required this.memory,
    this.aspectRatio,
    this.fill = false,
  });

  @override
  State<_HeroPhoto> createState() => _HeroPhotoState();
}

class _HeroPhotoState extends State<_HeroPhoto> {
  late final Future<List<String>> _future =
      PhotoService.resolvePhotoUrls(widget.memory);

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    Widget frame(Widget child) {
      final clipped = ClipRRect(borderRadius: radius, child: child);
      if (widget.fill) return clipped;
      return AspectRatio(aspectRatio: widget.aspectRatio ?? 1, child: clipped);
    }

    return FutureBuilder<List<String>>(
      future: _future,
      builder: (context, snap) {
        final urls = snap.data ?? const [];
        if (urls.isEmpty) {
          return frame(Container(
            color: AppColors.sageTint,
            child: const Center(
              child: Icon(Icons.image_outlined,
                  color: AppColors.softGray, size: 28),
            ),
          ));
        }
        return frame(CachedNetworkImage(
          imageUrl: urls.first,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          placeholder: (_, __) => Container(color: AppColors.sageTint),
          errorWidget: (_, __, ___) => Container(
            color: AppColors.sageTint,
            child: const Icon(Icons.broken_image_outlined,
                color: AppColors.softGray),
          ),
        ));
      },
    );
  }
}

/// CTA de conversion : « Transformer en livre ». Le tri des photos et
/// l'organisation chronologique sont déjà faits — c'est là que naît l'envie de
/// l'objet physique.
class _BookCta extends StatelessWidget {
  final VoidCallback onTap;
  const _BookCta({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.auto_stories_outlined, size: 20),
          label: const Text('Transformer en livre'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
        ),
      ),
    );
  }
}
