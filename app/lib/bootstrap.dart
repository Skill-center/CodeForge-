/// Bootstrap: error zones, prefs seeding, restored-state first frame.
///
/// SharedPreferences is awaited BEFORE runApp so the very first frame
/// already has the user's theme and layout — no default-state flash (G5).
/// The log file opens after the first frame, never before it (Phase 3 W1).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'application/provider_failure_logger.dart';
import 'application/providers.dart';
import 'core/logging/logger.dart';
import 'services/editor/bench/bench_pages.dart';
import 'services/editor/editor_page.dart';
import 'services/logging/file_log_sink.dart';
import 'services/perf/frame_stats.dart';
import 'services/settings/settings_store.dart';
import 'services/shell/shell_state.dart';

Future<void> bootstrap() async {
  final startup = runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      appLogger.sink = kDebugMode
          ? (record) => debugPrint(record.render())
          : null;

      // Chain to any previous handler (e.g. the integration-test binding's)
      // so errors are logged AND still surface to the test framework.
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        appLogger.error(
          'flutter',
          'framework_error',
          fields: {'error': details.exceptionAsString()},
        );
        (previousOnError ?? FlutterError.presentError)(details);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        appLogger.error('platform', 'uncaught', fields: {'error': '$error'});
        return true;
      };

      // The editor page's npm packages, next to the pub packages Flutter
      // lists by itself (About → Open-source licenses).
      LicenseRegistry.addLicense(bundledEditorLicenses);
      // The benchmark pages' packages, in the builds that bundle them.
      LicenseRegistry.addLicense(bundledBenchLicenses);
      // Settings → Developer → Frame timing (G6 on a real device).
      if (!kReleaseMode) {
        frameStats.start();
      }

      final prefs = await SharedPreferences.getInstance();
      final settingsStore = PrefsSettingsStore(prefs);
      final shellStore = PrefsShellStateStore(prefs);
      appLogger.info(
        'bootstrap',
        'stores_ready',
        fields: {'restoredRoute': shellStore.load().lastRoute},
      );

      runApp(
        ProviderScope(
          // Provider failures reach the log (Phase 3 W6).
          observers: const [ProviderFailureLogger()],
          overrides: [
            settingsStoreProvider.overrideWithValue(settingsStore),
            shellStateStoreProvider.overrideWithValue(shellStore),
          ],
          child: const CodeForgeApp(),
        ),
      );

      // The log file (About → Recent logs → Copy): what was logged so far,
      // then everything. Opened once the first frame is out, off its path;
      // if the folder cannot be written, the in-memory records carry on
      // alone.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(startFileLog(appLogger));
      });
    },
    (error, stack) {
      appLogger.error('zone', 'uncaught', fields: {'error': '$error'});
    },
  );
  await startup;
}
