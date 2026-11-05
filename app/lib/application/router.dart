/// GoRouter configuration (docs/ARCHITECTURE.md §4).
///
/// Initial location is the restored last route (whitelisted in ShellState).
/// The dev gallery exists only in debug/profile builds.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/home/home_screen.dart';
import '../features/settings/about_screen.dart';
import '../features/settings/appearance_screen.dart';
import '../features/settings/dev_gallery_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/workbench/workbench_screen.dart';
import 'shell_controller.dart';

final routerProvider = Provider<GoRouter>((ref) {
  ref.keepAlive();
  final initialRoute = ref.read(shellControllerProvider).lastRoute;
  final router = GoRouter(
    initialLocation: initialRoute,
    // Unknown locations (a stale or malformed deep link) land on home
    // instead of an error page (PHASE_1_PLAN 2.4).
    onException: (context, state, router) => router.go('/'),
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      GoRoute(
        path: '/workspace',
        builder: (context, state) => const WorkbenchScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
        routes: [
          GoRoute(
            path: 'appearance',
            builder: (context, state) => const AppearanceScreen(),
          ),
          GoRoute(
            path: 'about',
            builder: (context, state) => const AboutScreen(),
          ),
          if (kDebugMode)
            GoRoute(
              path: 'gallery',
              builder: (context, state) => const DevGalleryScreen(),
            ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
