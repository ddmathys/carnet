class AppConfig {
  // URL du backend (Vercel) qui détient les clés API (DeepSeek, Resend).
  // Aucune clé ne doit JAMAIS être embarquée dans l'app : tout passe par le
  // backend, authentifié par le token Firebase de l'utilisateur.
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://bloom-backend-gray.vercel.app',
  );

  static const String appDownloadUrl = 'https://dmathys.dev/download/carnet.apk';

  // Paiement en ligne (TWINT/carte via Stripe). `true` = bouton « Payer »
  // affiché. Mettre `false` pour revenir au paiement par facture (« à
  // réception ») si besoin. Nécessite STRIPE_SECRET_KEY côté backend.
  static const bool paymentEnabled = true;
}
