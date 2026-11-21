/// The session store's two sync modes on a phone (Phase 4 W5, ADR-0008).
///
/// Firebase Test Lab runs it with no computer attached, which the gate's
/// large-file test cannot do (its DevTools driver works through adb). The
/// Test Lab job builds the arm64 test app with this file as its Dart
/// entrypoint, and the instrumentation class SyncModesTest (in
/// android/app/src/androidTest/java/dev/codeforge/app/syncmodes/) starts it
/// through integration_test's FlutterTestRunner. The store is timed by the
/// large-file test's own code (storeTimings: 3 snapshots each of 1, 5 and
/// 10 MiB, then 20 one-character changes, with synchronous NORMAL and then
/// FULL, in a database of its own beside the app's), and the result is
/// printed as numbered CODEFORGE_SYNC_JSON lines, which the job reads back
/// from the device log (tool/ci/gate_results.py). Since Phase 4 W6 the same
/// entrypoint also runs search on the phone (phone_search_test.dart), whose
/// figures come back as CODEFORGE_SEARCH_JSON, and since Phase 5 W6 the
/// terminal's budgets (G6) and a folder's copy (phone_terminal_test.dart:
/// RUNTIME_GATE figures, CODEFORGE_TERMINAL_JSON and CODEFORGE_COPY_JSON).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:codeforge/services/platform/app_directories.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'large_files_test.dart' show storeTimings;
import 'phone_search_test.dart' show phoneSearchTests;
import 'phone_terminal_test.dart' show phoneTerminalTests;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store: synchronous NORMAL against FULL', (tester) async {
    final clock = Stopwatch()..start();
    final store = await storeTimings(await applicationFilesPath());
    final json = jsonEncode({
      'test': 'sync_modes',
      'debug': kDebugMode,
      'profile': kProfileMode,
      'ms': clock.elapsedMilliseconds,
      'store': store,
    });
    const size = 800;
    final parts = (json.length / size).ceil();
    for (var i = 0; i < parts; i += 1) {
      final end = math.min((i + 1) * size, json.length);
      final chunk = json.substring(i * size, end);
      debugPrint('CODEFORGE_SYNC_JSON ${i + 1}/$parts $chunk');
    }
    // debugPrint is throttled: let the queue drain before the test ends.
    await debugPrintDone;
  }, timeout: const Timeout(Duration(minutes: 10)));

  // Since Phase 4 W6, search on the same phone (phone_search_test.dart).
  phoneSearchTests();
  // Since Phase 5 W6, the terminal's budgets (G6) and a folder's copy
  // (phone_terminal_test.dart).
  phoneTerminalTests();
}
