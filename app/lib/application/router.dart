/// GoRouter configuration (docs/ARCHITECTURE.md §4).
///
/// Initial location is the restored last route (whitelisted in ShellState).
/// The dev gallery exists only in debug builds; the developer tools (editor
/// benchmark, frame timing, log viewer) in debug and profile builds.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/home/home_screen.dart';
import '../features/settings/about_screen.dart';
import '../features/settings/appearance_screen.dart';
import '../features/settings/dev_gallery_screen.dart';
import '../features/settings/developer/editor_benchmark_screen.dart';
import '../features/settings/developer/frame_timing_screen.dart';
import '../features/settings/developer/log_viewer_screen.dart';
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
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => _page(state, const HomeScreen()),
      ),
      GoRoute(
        path: '/workspace',
        pageBuilder: (context, state) => _page(state, const WorkbenchScreen()),
      ),
      GoRoute(
        path: '/settings',
        pageBuilder: (context, state) => _page(state, const SettingsScreen()),
        routes: [
          GoRoute(
            path: 'appearance',
            pageBuilder: (context, state) =>
                _page(state, const AppearanceScreen()),
          ),
          GoRoute(
            path: 'about',
            pageBuilder: (context, state) => _page(state, const AboutScreen()),
          ),
          if (kDebugMode)
            GoRoute(
              path: 'gallery',
              pageBuilder: (context, state) =>
                  _page(state, const DevGalleryScreen()),
            ),
          if (!kReleaseMode) ...[
            GoRoute(
              path: 'editor-benchmark',
              pageBuilder: (context, state) =>
                  _page(state, const EditorBenchmarkScreen()),
            ),
            GoRoute(
              path: 'frame-timing',
              pageBuilder: (context, state) =>
                  _page(state, const FrameTimingScreen()),
            ),
            GoRoute(
              path: 'logs',
              pageBuilder: (context, state) =>
                  _page(state, const LogViewerScreen()),
            ),
          ],
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

/// Every route's page: no transition, as routes have always changed.
///
/// go_router picks its own pages by the app it finds above the router:
/// Material pages, with Material's transitions, under its `MaterialApp`, and
/// otherwise this same `NoTransitionPage`. Its `MaterialApp` is
/// `package:material_ui`'s, which the app uses only since Phase 4 W1, so
/// until then go_router served `NoTransitionPage`s. Building them here keeps
/// navigation as it was; whether routes animate is a design decision for
/// later. Key, name, arguments and restoration id are the ones go_router
/// gives its own pages (go_router 18.1.3, `RouteBuilder`).
Page<void> _page(GoRouterState state, Widget child) => NoTransitionPage<void>(
  key: state.pageKey,
  name: state.name ?? state.path,
  arguments: <String, String>{
    ...state.pathParameters,
    ...state.uri.queryParameters,
  },
  restorationId: state.pageKey.value,
  child: child,
);
