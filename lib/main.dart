import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:app_links/app_links.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'core/services/notebook_share_service.dart';
import 'firebase_options.dart';
import 'core/theme/app_theme.dart';
import 'features/splash/splash_screen.dart';
import 'features/auth/welcome_screen.dart';
import 'features/auth/auth_screen.dart';
import 'features/children/add_child_screen.dart';
import 'features/children/home_screen.dart';
import 'features/children/child_timeline_screen.dart';
import 'features/milestones/add_milestone_screen.dart';
import 'features/growth/growth_screen.dart';
import 'features/children/summary_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/notebooks/notebook_create_template_screen.dart';
import 'features/notebooks/notebook_create_config_screen.dart';
import 'features/notebooks/notebook_dashboard_screen.dart';
import 'features/notebooks/notebook_edit_screen.dart';
import 'features/memories/memories_list_screen.dart';
import 'features/memories/memory_create_screen.dart';
import 'features/books/book_generate_screen.dart';
import 'features/books/book_history_screen.dart';
import 'features/subscription/subscription_screen.dart';
import 'features/books/multi_notebook_select_screen.dart';
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
    GoRoute(path: '/book/select', builder: (_, __) => const MultiNotebookSelectScreen()),
    GoRoute(
      path: '/book/new',
      builder: (_, state) {
        final ids = (state.uri.queryParameters['notebooks'] ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList();
        return BookGenerateScreen(notebookIds: ids);
      },
    ),

    // ── New notebook creation flow ──
    GoRoute(
      path: '/notebook/create/template',
      builder: (_, __) => const NotebookCreateTemplateScreen(),
    ),
    GoRoute(
      path: '/notebook/create/config',
      builder: (_, state) => NotebookCreateConfigScreen(
        type: state.uri.queryParameters['type'] ?? 'enfant',
      ),
    ),

    // ── Notebook screens ──
    GoRoute(
      path: '/notebook/:notebookId/dashboard',
      builder: (_, state) =>
          NotebookDashboardScreen(notebookId: state.pathParameters['notebookId']!),
    ),
    GoRoute(
      path: '/notebook/:notebookId/edit',
      builder: (_, state) =>
          NotebookEditScreen(notebookId: state.pathParameters['notebookId']!),
    ),
    GoRoute(
      path: '/notebook/:notebookId/memories',
      builder: (_, state) => MemoriesListScreen(
        notebookId: state.pathParameters['notebookId']!,
        initialFilter: state.uri.queryParameters['filter'],
      ),
    ),
    GoRoute(
      path: '/notebook/:notebookId/add-memory',
      builder: (_, state) => MemoryCreateScreen(
        notebookId: state.pathParameters['notebookId']!,
        startImport: state.uri.queryParameters['import'] == '1',
      ),
    ),
    GoRoute(
      path: '/notebook/:notebookId/edit-memory/:memoryId',
      builder: (_, state) => MemoryCreateScreen(
        notebookId: state.pathParameters['notebookId']!,
        memoryId: state.pathParameters['memoryId'],
      ),
    ),
    GoRoute(
      path: '/notebook/:notebookId/book',
      builder: (_, state) => BookGenerateScreen(
        notebookId: state.pathParameters['notebookId']!,
        startAtOrder: state.uri.queryParameters['order'] == '1',
      ),
    ),
    GoRoute(
      path: '/notebook/:notebookId/books',
      builder: (_, state) =>
          BookHistoryScreen(notebookId: state.pathParameters['notebookId']!),
    ),
    GoRoute(
      path: '/notebook/:notebookId/growth',
      builder: (_, state) => GrowthScreen(
        notebookId: state.pathParameters['notebookId']!,
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

    // ── Legacy child routes (kept during transition) ──
    GoRoute(path: '/add-child', builder: (_, __) => const AddChildScreen()),
    GoRoute(
      path: '/child/:childId',
      builder: (_, state) =>
          ChildTimelineScreen(childId: state.pathParameters['childId']!),
    ),
    GoRoute(
      path: '/child/:childId/journal',
      builder: (_, state) =>
          ChildTimelineScreen(childId: state.pathParameters['childId']!),
    ),
    GoRoute(
      path: '/child/:childId/add-milestone',
      builder: (_, state) =>
          AddMilestoneScreen(childId: state.pathParameters['childId']!),
    ),
    GoRoute(
      path: '/child/:childId/growth',
      builder: (_, state) =>
          GrowthScreen(notebookId: state.pathParameters['childId']!),
    ),
    GoRoute(
      path: '/child/:childId/summary',
      builder: (_, state) =>
          SummaryScreen(childId: state.pathParameters['childId']!),
    ),
    GoRoute(
      path: '/child/:childId/edit-milestone/:milestoneId',
      builder: (_, state) => AddMilestoneScreen(
        childId: state.pathParameters['childId']!,
        milestoneId: state.pathParameters['milestoneId'],
      ),
    ),
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

  // Gère carnet://join?token=… → rejoint le carnet puis y navigue.
  Future<void> _handleUri(Uri uri) async {
    final isJoin = uri.host == 'join' || uri.path.contains('join');
    if (!isJoin) return;
    final token = uri.queryParameters['token'];
    if (token == null || token.isEmpty) return;

    final result = await NotebookShareService.joinByToken(token);
    final messenger = _messengerKey.currentState;
    if (result != null) {
      _router.go('/notebook/${result.notebookId}/memories');
      messenger?.showSnackBar(
        SnackBar(content: Text('Tu as rejoint « ${result.title} » 🎉')),
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
