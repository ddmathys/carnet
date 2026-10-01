import 'package:flutter/material.dart';

class AppColors {
  // ── Marque terracotta (les noms "sage" sont conservés pour ne pas casser
  //    les écrans ; les valeurs sont désormais corail/terracotta) ──────────
  static const sageDark  = Color(0xFFE8896B); // corail — CTAs primaires, FAB
  // Liens et accents : remonté de #D9725A (4.07:1, juste sous le seuil) à
  // 4.52:1 sur le fond général.
  static const sage      = Color(0xFFDC7E68); // corail foncé — liens, accents
  static const sageLight = Color(0xFFF3C0B0); // corail clair — tints
  static const sageTint  = Color(0xFF6A5439); // tint — fond des chips

  // ── Backgrounds — ton « terre chaude » (espresso clarifié) ───────────────
  static const background = Color(0xFF3B2E21); // fond général
  // `white` reste litéralement blanc. ⚠️ Ce n'est PAS la bonne couleur de
  // texte sur un fond corail : blanc sur `sageDark` ne donne que 2.55:1, loin
  // du 4.5:1 exigé par WCAG AA — et c'était le cas de TOUS les boutons
  // primaires de l'app (audit du 01.10.26). Sur un accent chaud (corail,
  // ambre, rouge, toile), la couleur de texte est `onAccent`. Le blanc reste
  // valable sur les fonds FONCÉS (vert `coverGreen`, surimpression de photo).
  static const white      = Color(0xFFFFFFFF);
  // Texte et icônes posés sur un accent chaud. Même valeur que `ink` (texte
  // sur fond clair) : 5.98:1 sur le corail des boutons, 7.11:1 sur l'ambre,
  // 4.47:1 sur le rouge d'erreur — tous conformes AA.
  static const onAccent   = Color(0xFF2D2416);
  static const surface    = Color(0xFF4F3F2E); // cartes, feuilles, champs
  static const cream      = Color(0xFF453626); // surface secondaire (espresso)
  static const beige      = Color(0xFF3B2E21); // alias de background

  // ── Neutrals ───────────────────────────────────────────────────────────
  static const textDark   = Color(0xFFF3E8DE); // texte principal, clair
  static const textMedium = Color(0xFFD4C5B3); // gris chaud, texte secondaire
  // Placeholders : remonté de #8C7A68 (2.45:1 sur `surface`, illisible) à
  // 4.54:1 — un indice de saisie reste du texte, il doit se lire.
  static const softGray   = Color(0xFFB8ACA0); // placeholders, discret
  // Contour discret des cartes (décoratif : pas de seuil WCAG).
  static const border     = Color(0xFF6A5439);
  // Contour des CHAMPS de saisie : celui-là porte une information (où taper,
  // quel champ est en erreur) et doit atteindre 3:1. #6A5439 n'était qu'à
  // 1.41:1 sur `surface` — le champ était invisible.
  static const borderStrong = Color(0xFFA8875E);

  // ── Texte sur fond CLAIR (polaroïds blancs, bandeaux clairs) — l'inverse de
  //    textDark/textMedium, qui supposent un fond sombre ────────────────────
  static const ink       = Color(0xFF2D2416); // texte principal sur fond clair
  static const inkMedium = Color(0xFF7A6A5A); // texte secondaire sur fond clair

  // ── Accents ────────────────────────────────────────────────────────────
  static const earth     = Color(0xFFE0A65E); // jaune-doré (accent chaud)
  static const darkEarth = Color(0xFFB87A45);
  static const amber     = Color(0xFFE0A65E);
  static const error     = Color(0xFFE0645C); // fond de bouton destructif
  // Message d'erreur EN TEXTE sur fond sombre : #E0645C n'atteint que 3.84:1
  // sur le fond et 2.95:1 sur une carte. Celui-ci passe AA sur les deux.
  static const errorText = Color(0xFFEA9893);
  static const success   = Color(0xFF8FAE7A); // vert doux, lisible sur fond sombre

  // ── Cover palette ──────────────────────────────────────────────────────
  static const coverGreen  = Color(0xFF3A6648);
  static const coverAmber  = Color(0xFFC98A1A);
  static const coverBlue   = Color(0xFF4A8AC9);
  static const coverPink   = Color(0xFFB94A7A);
  static const coverViolet = Color(0xFF8A6AAE);
  static const coverGray   = Color(0xFF888880);

  static const coverColors = [
    coverGreen, coverAmber, coverBlue, coverPink, coverViolet, coverGray,
  ];
  static const coverHexColors = [
    '#3A6648', '#C98A1A', '#4A8AC9', '#B94A7A', '#8A6AAE', '#888880',
  ];

  // ── Gradient ───────────────────────────────────────────────────────────
  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFEE9C80), sage],
    stops: [0.0, 1.0],
  );
}

class AppTheme {
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.sage,
          brightness: Brightness.dark,
          primary: AppColors.sageDark,
          secondary: AppColors.earth,
          surface: AppColors.surface,
          error: AppColors.error,
        ),
        scaffoldBackgroundColor: AppColors.background,

        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.background,
          foregroundColor: AppColors.textDark,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),

        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.sageDark,
            // `onAccent` et pas `white` : voir AppColors.white.
            foregroundColor: AppColors.onAccent,
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontFamily: 'DMSans',
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
            elevation: 0,
          ),
        ),

        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.sage,
            side: const BorderSide(color: AppColors.sage),
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),

        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.sage,
          ),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.borderStrong),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.borderStrong),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.sage, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.error),
          ),
          labelStyle: const TextStyle(color: AppColors.textMedium),
          hintStyle: const TextStyle(color: AppColors.softGray),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),

        cardTheme: CardThemeData(
          color: AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.border, width: 0.5),
          ),
        ),

        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: AppColors.sageDark,
          foregroundColor: AppColors.onAccent,
          elevation: 2,
        ),

        fontFamily: 'DMSans',
      );
}
