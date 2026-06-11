class AppConfig {
  // URL du backend (Vercel) qui détient les clés API (DeepSeek, Resend).
  // Aucune clé ne doit JAMAIS être embarquée dans l'app : tout passe par le
  // backend, authentifié par le token Firebase de l'utilisateur.
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://bloom-backend.vercel.app',
  );

  static const String appDownloadUrl = 'https://dmathys.dev/download/carnet.apk';
}
