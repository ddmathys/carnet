import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:app_links/app_links.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
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
import 'features/books/book_generate_screen.dart';
import 'features/books/book_history_screen.dart';
import 'features/books/memory_select_screen.dart';
import 'features/subscription/subscription_screen.dart';
import 'features/orders/order_tracking_screen.dart';
import 'features/orders/order_confirmation_screen.dart';
import 'features/admin/admin_orders_screen.dart';
import 'features/admin/admin_users_screen.dart';

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
    GoRoute(path: '/subscription', builder: (_, __) => const SubscriptionScreen()),

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
        initialTagId: state.uri.queryParameters['tag'],
      ),
    ),
    GoRoute(
      path: '/memory/:memoryId/edit',
      builder: (_, state) =>
          MemoryCreateScreen(memoryId: state.pathParameters['memoryId']!),
    ),

    // ── Livres ──
    GoRoute(
      path: '/book/select',
      builder: (_, state) =>
          MemorySelectScreen(initialTagId: state.uri.queryParameters['tag']),
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
        );
      },
    ),
    GoRoute(path: '/books', builder: (_, __) => const BookHistoryScreen()),

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
    GoRoute(path: '/admin/users', builder: (_, __) => const AdminUsersScreen()),
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

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
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
    );
  }
}
