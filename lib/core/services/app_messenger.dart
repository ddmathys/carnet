import 'package:flutter/material.dart';

/// Clé globale du ScaffoldMessenger de l'app — un SnackBar affiché via cette
/// clé survit à une navigation immédiate (ex. context.go() juste après),
/// contrairement à ScaffoldMessenger.of(context), lié à l'écran qu'on quitte
/// et donc coupé net si on navigue avant que le SnackBar ait eu le temps de
/// s'afficher.
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
