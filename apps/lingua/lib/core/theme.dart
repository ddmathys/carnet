import 'package:flutter/material.dart';

/// Thème unique de l'app. Volontairement minimal : Material 3 et une couleur
/// de base, le reste vient du ColorScheme généré.
ThemeData buildLinguaTheme() {
  return ThemeData(
    useMaterial3: true,
    colorSchemeSeed: const Color(0xFF2F6F5E),
    brightness: Brightness.light,
  );
}

ThemeData buildLinguaDarkTheme() {
  return ThemeData(
    useMaterial3: true,
    colorSchemeSeed: const Color(0xFF2F6F5E),
    brightness: Brightness.dark,
  );
}
