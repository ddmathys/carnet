import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Bibliothèque : rendu d'un carnet ou d'un souvenir sous forme de livre posé
/// sur une étagère en bois. Réutilisé par le dashboard (carnets) et l'écran des
/// souvenirs (même disposition).

// Palette bois / papier (reprise de la maquette carnets-preview-3d).
const _wood = Color(0xFF6B4A32);
const _woodDark = Color(0xFF4A3220);
const _woodLight = Color(0xFF8A6242);
const _gold = Color(0xFFCBA876);

/// Un livre : couverture photo dominante + tranche + bande titre.
class ShelfBook extends StatelessWidget {
  final String? coverUrl;
  final Color coverColor;
  final String? emoji;
  final String title;
  final String kind; // petit label au-dessus du titre (type / date)
  final double width;
  final double height;
  final double tilt; // rotation Y (rad) — 0 = livre de face
  final String? flag; // pastille (ex. "Démo")
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const ShelfBook({
    super.key,
    required this.coverUrl,
    required this.coverColor,
    required this.title,
    required this.kind,
    this.emoji,
    this.width = 96,
    this.height = 176,
    this.tilt = 0,
    this.flag,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    Widget cover = ClipRRect(
      borderRadius: const BorderRadius.horizontal(
        left: Radius.circular(3),
        right: Radius.circular(6),
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Couverture : photo ou couleur + emoji
            if (coverUrl != null && coverUrl!.isNotEmpty)
              CachedNetworkImage(
                imageUrl: coverUrl!,
                fit: BoxFit.cover,
                placeholder: (_, __) => _fallback(),
                errorWidget: (_, __, ___) => _fallback(),
              )
            else
              _fallback(),

            // Tranche (spine) sombre à gauche
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 9,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF2C2018), Color(0x00000000)],
                  ),
                ),
              ),
            ),

            // Tranche de pages (droite)
            Positioned(
              right: 0,
              top: 3,
              bottom: 3,
              width: 4,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0x33000000), Color(0xFFEFE7D4)],
                  ),
                ),
              ),
            ),

            // Bande titre en bas
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 18, 10, 9),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xE6141C14), Color(0x00141C14)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (kind.isNotEmpty)
                      Text(
                        kind.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 7.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                        ),
                      ),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'PlayfairDisplay',
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.05,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Pastille
            if (flag != null)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: _gold,
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Text(
                    flag!.toUpperCase(),
                    style: const TextStyle(
                      color: Color(0xFF2A1E12),
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    Widget book = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.32),
            blurRadius: 22,
            offset: const Offset(4, 14),
          ),
        ],
      ),
      child: cover,
    );

    if (tilt != 0) {
      book = Transform(
        alignment: Alignment.centerLeft,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0015)
          ..rotateY(tilt),
        child: book,
      );
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: book,
    );
  }

  Widget _fallback() {
    return Container(
      color: coverColor,
      alignment: Alignment.center,
      child: Text(emoji ?? '📔', style: const TextStyle(fontSize: 34)),
    );
  }
}

/// Une planche en bois (support des livres).
class ShelfPlank extends StatelessWidget {
  final EdgeInsets margin;
  const ShelfPlank(
      {super.key,
      this.margin = const EdgeInsets.fromLTRB(22, 8, 22, 30)});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 15,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_woodLight, _wood, _woodDark],
          stops: [0.0, 0.45, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3C2814).withOpacity(0.5),
            blurRadius: 22,
            offset: const Offset(0, 14),
          ),
        ],
      ),
    );
  }
}

/// Étagère horizontale défilante (dashboard : peu de carnets).
/// [onAdd] ≠ null → un bouton « + » (aux mêmes dimensions qu'un livre) est
/// ajouté à la fin de la rangée pour créer un nouveau carnet.
class BookShelfRail extends StatelessWidget {
  final List<ShelfBook> books;
  final VoidCallback? onAdd;
  const BookShelfRail({super.key, required this.books, this.onAdd});

  @override
  Widget build(BuildContext context) {
    // Hauteur/largeur de référence (tous les livres partagent le même format).
    final refW = books.isNotEmpty ? books.first.width : 104.0;
    final refH = books.fold<double>(0, (m, b) => b.height > m ? b.height : m);
    final maxH = refH > 0 ? refH : 176.0;
    final itemCount = books.length + (onAdd != null ? 1 : 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: maxH + 14,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(26, 12, 26, 0),
            itemCount: itemCount,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final isAdd = onAdd != null && i == books.length;
              return SizedBox(
                width: isAdd ? refW : books[i].width,
                height: maxH + 14,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: isAdd
                      ? _AddBook(width: refW, height: maxH, onTap: onAdd!)
                      : books[i],
                ),
              );
            },
          ),
        ),
        const ShelfPlank(),
      ],
    );
  }
}

/// Tuile « + » au format d'un livre, pour ajouter un carnet depuis l'étagère.
class _AddBook extends StatelessWidget {
  final double width;
  final double height;
  final VoidCallback onTap;
  const _AddBook(
      {required this.width, required this.height, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFFF3E9DC).withOpacity(0.55),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: _gold.withOpacity(0.8),
            width: 1.4,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, color: _woodDark.withOpacity(0.8), size: 28),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Nouveau\ncarnet',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _woodDark.withOpacity(0.85),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Étagères empilées (souvenirs : plusieurs rangées de livres posés).
/// Découpe la liste en rangées de [perRow] livres, chaque rangée sur sa planche.
class BookShelfGrid extends StatelessWidget {
  final List<ShelfBook> books;
  final int perRow;
  const BookShelfGrid({super.key, required this.books, this.perRow = 3});

  @override
  Widget build(BuildContext context) {
    final rowH = books.fold<double>(0, (m, b) => b.height > m ? b.height : m);
    final rows = <List<ShelfBook>>[];
    for (var i = 0; i < books.length; i += perRow) {
      rows.add(books.sublist(
          i, i + perRow > books.length ? books.length : i + perRow));
    }
    return Column(
      children: [
        for (final row in rows) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var j = 0; j < perRow; j++)
                  Expanded(
                    child: j < row.length
                        ? SizedBox(
                            height: rowH + 6,
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: row[j],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
          const ShelfPlank(margin: EdgeInsets.fromLTRB(14, 8, 14, 26)),
        ],
      ],
    );
  }
}
