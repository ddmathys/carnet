import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'firebase_options.dart';
import 'core/theme/app_theme.dart';
import 'features/splash/splash_screen.dart';
import 'features/auth/auth_screen.dart';
import 'features/children/add_child_screen.dart';
import 'features/children/home_screen.dart';
import 'features/children/child_timeline_screen.dart';
import 'features/milestones/add_milestone_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await initializeDateFormatting('fr', null);
  runApp(const ProviderScope(child: BloomApp()));
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, __) => const SplashScreen()),
    GoRoute(path: '/auth', builder: (_, __) => const AuthScreen()),
    GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
    GoRoute(path: '/add-child', builder: (_, __) => const AddChildScreen()),
    GoRoute(
      path: '/child/:childId',
      builder: (_, state) =>
          ChildTimelineScreen(childId: state.pathParameters['childId']!),
    ),
    GoRoute(
      path: '/child/:childId/add-milestone',
      builder: (_, state) =>
          AddMilestoneScreen(childId: state.pathParameters['childId']!),
    ),
  ],
);

class BloomApp extends StatelessWidget {
  const BloomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Bloom',
      theme: AppTheme.light,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
