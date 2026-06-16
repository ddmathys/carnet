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
  // (« à réception »), le bouton « Payer » est masqué. Repasser à `true` quand
  // Stripe est configuré (STRIPE_SECRET_KEY côté backend) pour activer TWINT.
  static const bool paymentEnabled = false;
}
