/// Bootstrap: error zones, prefs seeding, restored-state first frame.
///
/// SharedPreferences is awaited BEFORE runApp so the very first frame
/// already has the user's theme and layout — no default-state flash (G5).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'application/providers.dart';
import 'core/logging/logger.dart';
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
          overrides: [
            settingsStoreProvider.overrideWithValue(settingsStore),
            shellStateStoreProvider.overrideWithValue(shellStore),
          ],
          child: const CodeForgeApp(),
        ),
      );
    },
    (error, stack) {
      appLogger.error('zone', 'uncaught', fields: {'error': '$error'});
    },
  );
  await startup;
}
