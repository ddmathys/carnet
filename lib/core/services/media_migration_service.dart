import 'package:flutter/foundation.dart';
import 'backend_client.dart';

/// Reprise des médias restés sur Firebase Storage → R2.
///
/// Tout le travail est fait par le backend (lui seul a les clés R2 et l'accès
/// au Storage) ; l'app ne fait que le réveiller lot par lot, en tâche de fond,
/// jusqu'à ce qu'il n'y ait plus rien à migrer. Aucun média ne transite par le
/// téléphone : ni données mobiles, ni batterie.
///
/// Idempotent : ce qui est déjà sur R2 n'a plus d'URL Firebase, donc n'est plus
/// vu comme « à migrer ». Une session interrompue reprend simplement au lot
/// suivant au prochain démarrage.
class MediaMigrationService {
  static bool _running = false;

  /// Lance la migration sans bloquer le démarrage (feu et oubli).
  static void runInBackground() {
    if (_running) return;
    _running = true;
    _run().whenComplete(() => _running = false);
  }

  static Future<void> _run() async {
    // Garde-fou : un compte avec beaucoup d'anciens médias sera fini au
    // lancement suivant plutôt que de tourner indéfiniment.
    const maxBatches = 40;
    for (var i = 0; i < maxBatches; i++) {
      try {
        final data = await BackendClient.postJson(
          '/api/video/migrate',
          {'limit': 5},
          timeout: const Duration(seconds: 60),
        );
        if (data == null) return; // hors ligne / backend indisponible
        final remaining = (data['remaining'] as num?)?.toInt() ?? 0;
        final moved = ((data['photos'] as num?)?.toInt() ?? 0) +
            ((data['audios'] as num?)?.toInt() ?? 0) +
            ((data['pdfs'] as num?)?.toInt() ?? 0);
        debugPrint('MediaMigration: lot migré ($moved), reste $remaining');
        if (remaining <= 0) return;
        // Rien n'a bougé alors qu'il reste du travail → on n'insiste pas, sinon
        // on boucle sur un fichier fautif à chaque démarrage.
        if (moved == 0) return;
      } catch (e) {
        debugPrint('MediaMigration: interrompue — $e');
        return;
      }
    }
  }
}
