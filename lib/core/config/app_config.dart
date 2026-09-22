class AppConfig {
  // URL du backend (Vercel) qui détient les clés API (DeepSeek, Resend).
  // Aucune clé ne doit JAMAIS être embarquée dans l'app : tout passe par le
  // backend, authentifié par le token Firebase de l'utilisateur.
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://bloom-backend-gray.vercel.app',
  );

  static const String appDownloadUrl = 'https://dmathys.dev/download/carnet.apk';

  // Paiement en ligne (TWINT/carte via Stripe). `false` = paiement par FACTURE
  // (« à réception »), le bouton « Payer » est masqué.
  // Activé le 22.09.26 : STRIPE_SECRET_KEY + STRIPE_WEBHOOK_SECRET posées sur
  // Vercel, TWINT activé côté Stripe — pour l'instant en mode TEST (clé
  // sk_test_…, aucun montant réel prélevé). Repasser STRIPE_SECRET_KEY /
  // STRIPE_WEBHOOK_SECRET sur les valeurs LIVE du dashboard Stripe (mode
  // production, pas test) avant d'encaisser de vrais clients.
  static const bool paymentEnabled = true;

  // Seul compte avec accès à la console admin et au raccourci « Commander »
  // en un écran. Garder cette valeur unique : elle était dupliquée dans
  // plusieurs écrans avant de devenir cette constante.
  static const String adminEmail = 'david.mathys24@gmail.com';
}
