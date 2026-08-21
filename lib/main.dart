import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:app_links/app_links.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'core/services/notification_service.dart';
import 'core/services/shared_media_service.dart';
import 'core/services/tag_service.dart';
import 'firebase_options.dart';
import 'core/theme/app_theme.dart';
import 'features/splash/splash_screen.dart';
import 'features/auth/welcome_screen.dart';
import 'features/auth/auth_screen.dart';
import 'features/children/home_screen.dart';
import 'features/growth/growth_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/memories/memories_list_screen.dart';
import 'features/memories/memory_create_screen.dart';
import 'features/memories/memory_detail_screen.dart';
import 'features/books/book_generate_screen.dart';
import 'features/books/book_history_screen.dart';
import 'features/books/memory_select_screen.dart';
import 'features/posters/poster_select_screen.dart';
import 'features/posters/poster_generate_screen.dart';
import 'features/orders/order_tracking_screen.dart';
import 'features/orders/order_confirmation_screen.dart';
import 'features/admin/admin_orders_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await initializeDateFormatting('fr', null);

  // Android : bascule sur le Photo Picker système (Android 13+, rétroporté via
  // Google Play services). C'est le seul sélecteur où la multi-sélection de
  // vidéos est fiable ; sans ça, image_picker utilise le vieux GET_CONTENT qui
  // ne renvoie souvent qu'un seul élément.
  final picker = ImagePickerPlatform.instance;
  if (picker is ImagePickerAndroid) {
    picker.useAndroidPhotoPicker = true;
  }

  // Partage entrant : « Partager » depuis Google Photos et consorts. On amorce
  // l'écoute avant le premier écran, sans l'attendre (la copie des fichiers peut
  // durer sur une grosse vidéo — c'est le splash qui patiente).
  SharedMediaService.init();

  runApp(const ProviderScope(child: BloomApp()));
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, __) => const SplashScreen()),
    GoRoute(path: '/welcome', builder: (_, __) => const WelcomeScreen()),
    GoRoute(
      path: '/auth',
      builder: (_, state) =>
          AuthScreen(initialMode: state.uri.queryParameters['mode']),
    ),
    GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
    GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),

    // ── Souvenirs (organisés par tags, plus par carnets) ──
    GoRoute(
      path: '/memories',
      builder: (_, state) =>
          MemoriesListScreen(initialTagId: state.uri.queryParameters['tag']),
    ),
    GoRoute(
      path: '/memory/new',
      builder: (_, state) => MemoryCreateScreen(
        startImport: state.uri.queryParameters['import'] == '1',
        // `shared=1` : ouvert depuis le partage Android, les médias reçus sont
        // récupérés auprès de SharedMediaService.
        startShared: state.uri.queryParameters['shared'] == '1',
        initialTagId: state.uri.queryParameters['tag'],
      ),
    ),
    GoRoute(
      path: '/memory/:memoryId/edit',
      builder: (_, state) =>
          MemoryCreateScreen(memoryId: state.pathParameters['memoryId']!),
    ),
    // Vue LECTURE d'un souvenir (taper un polaroïd). « /edit » ouvre le
    // formulaire. Placée APRÈS /new et /:id/edit pour ne pas les capter.
    GoRoute(
      path: '/memory/:memoryId',
      builder: (_, state) =>
          MemoryDetailScreen(memoryId: state.pathParameters['memoryId']!),
    ),

    // ── Livres ──
    GoRoute(
      path: '/book/select',
      builder: (_, state) => MemorySelectScreen(
        initialTagId: state.uri.queryParameters['tag'],
        editOrderId: state.uri.queryParameters['editOrder'],
      ),
    ),
    GoRoute(
      path: '/book/new',
      builder: (_, state) {
        final ids = (state.uri.queryParameters['memories'] ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList();
        return BookGenerateScreen(
          memoryIds: ids,
          tagId: state.uri.queryParameters['tag'],
          startAtOrder: state.uri.queryParameters['order'] == '1',
          editOrderId: state.uri.queryParameters['editOrder'],
        );
      },
    ),
    GoRoute(path: '/books', builder: (_, __) => const BookHistoryScreen()),

    // ── Posters ──
    GoRoute(
      path: '/poster/select',
      builder: (_, state) => PosterSelectScreen(
        editOrderId: state.uri.queryParameters['editOrder'],
      ),
    ),
    GoRoute(
      path: '/poster/new',
      builder: (_, state) {
        // Format `memoryId:photoIndex,memoryId:photoIndex,...` — une entrée
        // par PHOTO choisie (pas par souvenir, un souvenir peut en fournir
        // plusieurs). Voir poster_select_screen.dart::_continue.
        final refs = (state.uri.queryParameters['photos'] ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .map((s) {
              final parts = s.split(':');
              return (
                memoryId: parts[0],
                photoIndex: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
              );
            })
            .toList();
        return PosterGenerateScreen(
          photoRefs: refs,
          editOrderId: state.uri.queryParameters['editOrder'],
        );
      },
    ),

    // ── Croissance (tags « enfant ») ──
    GoRoute(
      path: '/growth/:tagId',
      builder: (_, state) => GrowthScreen(
        tagId: state.pathParameters['tagId']!,
        startAddMeasure: state.uri.queryParameters['add'] == '1',
      ),
    ),

    // ── Orders ──
    GoRoute(path: '/orders', builder: (_, __) => const OrdersListScreen()),
    GoRoute(
      path: '/orders/:orderId',
      builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['orderId']!),
    ),
    GoRoute(
      path: '/order-confirmation/:orderId',
      builder: (_, state) => OrderConfirmationScreen(orderId: state.pathParameters['orderId']!),
    ),

    // ── Admin ──
    GoRoute(path: '/admin/orders', builder: (_, __) => const AdminOrdersScreen()),
  ],
);

final _messengerKey = GlobalKey<ScaffoldMessengerState>();

class BloomApp extends StatefulWidget {
  const BloomApp({super.key});

  @override
  State<BloomApp> createState() => _BloomAppState();
}

class _BloomAppState extends State<BloomApp> {
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  StreamSubscription<List<SharedMediaItem>>? _sharedMediaSub;
  StreamSubscription? _notificationTapSub;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
    _initSharedMedia();
    // Notification « souvenir du jour » tapée appli déjà lancée → on ouvre le
    // souvenir. (Appli fermée : c'est le splash qui s'en charge.)
    _notificationTapSub = NotificationService.listenTaps(
      (memoryId) => _router.push('/memory/$memoryId'),
    );
  }

  /// Partage reçu alors que l'appli est déjà ouverte : on saute directement au
  /// formulaire de souvenir, médias attachés. (Le cas « appli fermée » est géré
  /// par le splash, qui connaît l'état de connexion avant de router.)
  void _initSharedMedia() {
    _sharedMediaSub = SharedMediaService.stream.listen((items) {
      if (items.isEmpty) return;
      if (FirebaseAuth.instance.currentUser == null) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('Connecte-toi à Carnet, puis repartage tes médias.'),
          ),
        );
        return;
      }
      // `push` (et pas `go`) : on empile par-dessus l'écran en cours, ce qui
      // crée bien un nouveau formulaire même si l'utilisateur en avait déjà un
      // d'ouvert, et le retour ramène là où il était.
      // Partage passé par un raccourci « Ajouter à … » → tag pré-coché.
      final tagId = SharedMediaService.pendingTagId;
      _router.push(
        '/memory/new?shared=1${tagId != null ? '&tag=$tagId' : ''}',
      );
    });
  }

  Future<void> _initDeepLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handleUri(initial);
    } catch (_) {}
    _linkSub = _appLinks.uriLinkStream.listen(_handleUri, onError: (_) {});
  }

  // Gère carnet://join?token=… → rejoint le TAG partagé puis affiche ses souvenirs.
  Future<void> _handleUri(Uri uri) async {
    final isJoin = uri.host == 'join' || uri.path.contains('join');
    if (!isJoin) return;
    final token = uri.queryParameters['token'];
    if (token == null || token.isEmpty) return;

    final result = await TagService.joinByToken(token);
    final messenger = _messengerKey.currentState;
    if (result != null) {
      _router.go('/memories?tag=${result.tagId}');
      messenger?.showSnackBar(
        SnackBar(content: Text('Tu as rejoint « ${result.label} » 🎉')),
      );
    } else {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
              'Lien invalide ou expiré — connecte-toi puis rouvre le lien.'),
        ),
      );
    }
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _sharedMediaSub?.cancel();
    _notificationTapSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Folio',
      theme: AppTheme.light,
      routerConfig: _router,
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        // Beaucoup de boutons/tuiles ont une hauteur fixe (ex.
        // Size.fromHeight(52)) — un texte système fortement agrandi (réglage
        // fréquent chez les grands-parents, un vrai public de cette app) les
        // ferait déborder. On laisse le texte grossir (accessibilité) mais on
        // plafonne à 1.3x plutôt que de le laisser casser la mise en page.
        final scaler = MediaQuery.textScalerOf(context).clamp(
          minScaleFactor: 1.0,
          maxScaleFactor: 1.3,
        );
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaler),
          child: child!,
        );
      },
    );
  }
}
