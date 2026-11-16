/// Gate G3, part B (Phase 4 W3): the warm start. Part A
/// (runtime_a_test.dart) installed the runtime; the gate then killed the
/// process. Here the app comes back over the same files, the workbench
/// starts the runtime, and nothing is extracted: the install marker
/// matches this APK's payload, the executables' links are checked, and the
/// audit runs again. app/tool/ci/emulator_gate.sh reads the RUNTIME_UI line.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp, pumpUntil;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('runtime B: a warm start after the process died', (tester) async {
    // Part A's settings: the welcome is gone, and the workbench may come
    // back by itself.
    final prefs = await SharedPreferences.getInstance();
    await pumpRealApp(tester, prefs);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final demo = find.byKey(const ValueKey('explore_demo'));
    if (demo.evaluate().isNotEmpty) {
      await tester.ensureVisible(demo);
      await tester.pumpAndSettle();
      await tester.tap(demo);
      await tester.pump();
    }

    await pumpUntil(
      tester,
      () {
        final status = container.read(runtimeControllerProvider);
        return (status.usable && !status.auditing) ||
            status.state == RuntimeState.failed ||
            status.state == RuntimeState.unavailable;
      },
      what: 'the runtime to start warm and audit',
      timeout: const Duration(minutes: 8),
    );
    final status = container.read(runtimeControllerProvider);
    final audit = status.audit;
    debugPrint(
      'RUNTIME_UI warm_start state=${status.state.name} '
      'warm_start_ms=${status.warmStartMs} relinked=${status.relinked} '
      'install_ms=${status.installMs} outside_apk=${audit?.outsideApk} '
      'shipped=${audit?.shipped} audit_ms=${audit?.millis} '
      'problem=${status.problem?.name} detail=${status.detail}',
    );
    expect(status.state, RuntimeState.ready, reason: status.detail);
    // Only the warm path sets it: an install would have cleared it.
    expect(
      status.warmStartMs,
      isNotNull,
      reason: 'the runtime was installed again',
    );
    if ((status.relinked ?? 0) == 0) {
      expect(
        status.warmStartMs!,
        lessThanOrEqualTo(100),
        reason: 'G3: a warm start takes 100 ms or less',
      );
    } else {
      // `flutter test` installed this APK over part A's, as an update would:
      // Android gave it a new native library directory, and the warm start
      // pointed every executable's link at it, extracting nothing. The 100 ms
      // budget is judged without that, by the instrumented tests.
      expect(status.warmStartMs!, lessThan(2000));
    }
    expect(audit, isNotNull);
    expect(audit!.outsideApk, 0, reason: audit.report);
    expect(audit.truncated, isFalse);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
