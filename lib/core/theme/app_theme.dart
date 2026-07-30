import 'package:flutter/material.dart';

class AppColors {
  // ── Marque terracotta (les noms "sage" sont conservés pour ne pas casser
  //    les écrans ; les valeurs sont désormais corail/terracotta) ──────────
  static const sageDark  = Color(0xFFE8896B); // corail — CTAs primaires, FAB
  static const sage      = Color(0xFFD9725A); // corail foncé — liens, accents
  static const sageLight = Color(0xFFF3C0B0); // corail clair — tints
  static const sageTint  = Color(0xFF6A5439); // tint — fond des chips

  // ── Backgrounds — ton « terre chaude » (espresso clarifié) ───────────────
  static const background = Color(0xFF3B2E21); // fond général
  // `white` reste litéralement blanc : c'est la couleur du TEXTE/ICÔNES posés
  // sur les fonds colorés (boutons corail, badges…), qui ne doit jamais
  // s'assombrir. Le fond des CARTES/FEUILLES sombres est `surface`.
  static const white      = Color(0xFFFFFFFF);
  static const surface    = Color(0xFF4F3F2E); // cartes, feuilles, champs
  static const cream      = Color(0xFF453626); // surface secondaire (espresso)
  static const beige      = Color(0xFF3B2E21); // alias de background

  // ── Neutrals ───────────────────────────────────────────────────────────
  static const textDark   = Color(0xFFF3E8DE); // texte principal, clair
  static const textMedium = Color(0xFFD4C5B3); // gris chaud, texte secondaire
  static const softGray   = Color(0xFF8C7A68); // placeholders, discret
  static const border     = Color(0xFF6A5439);

  // ── Texte sur fond CLAIR (polaroïds blancs, bandeaux clairs) — l'inverse de
  //    textDark/textMedium, qui supposent un fond sombre ────────────────────
  static const ink       = Color(0xFF2D2416); // texte principal sur fond clair
  static const inkMedium = Color(0xFF7A6A5A); // texte secondaire sur fond clair

  // ── Accents ────────────────────────────────────────────────────────────
  static const earth     = Color(0xFFE0A65E); // jaune-doré (accent chaud)
  static const darkEarth = Color(0xFFB87A45);
  static const amber     = Color(0xFFE0A65E);
  static const error     = Color(0xFFE0645C);
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
            foregroundColor: AppColors.white,
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
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.border),
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
          foregroundColor: AppColors.white,
          elevation: 2,
        ),

        fontFamily: 'DMSans',
      );
}
