/// Gate G3, part A (Phase 4 W3): the sealed runtime's first install,
/// through the real app on the emulator. Opening a workspace starts it; it
/// installs off the UI thread while the editor works, then audits clean.
/// The gate kills the process afterwards, and part B (runtime_b_test.dart)
/// starts it warm. app/tool/ci/emulator_gate.sh reads the RUNTIME_UI lines.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
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

  testWidgets('runtime A: the first install, from opening a workspace', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await pumpRealApp(tester, prefs);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    // Nothing installs before a workspace opens.
    final before = container.read(runtimeControllerProvider);
    debugPrint('RUNTIME_UI before_open state=${before.state.name}');
    expect(
      before.state,
      isNot(anyOf(RuntimeState.installing, RuntimeState.ready)),
    );

    await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();
    final opened = DateTime.now();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pump();

    // The editor works while the runtime installs: the first file opens.
    await pumpUntil(
      tester,
      () => container.read(documentControllerProvider).isOpen('main.js'),
      what: 'main.js to open',
    );
    final installing = container.read(runtimeControllerProvider);
    debugPrint(
      'RUNTIME_UI editor_open state=${installing.state.name} '
      'done=${installing.done} total=${installing.total}',
    );

    var progressSeen = 0;
    await pumpUntil(
      tester,
      () {
        final status = container.read(runtimeControllerProvider);
        if (status.state == RuntimeState.installing && status.total > 0) {
          progressSeen++;
        }
        return (status.usable && !status.auditing) ||
            status.state == RuntimeState.failed ||
            status.state == RuntimeState.unavailable;
      },
      what: 'the runtime to install and audit',
      timeout: const Duration(minutes: 12),
    );
    final status = container.read(runtimeControllerProvider);
    final audit = status.audit;
    final elapsed = DateTime.now().difference(opened).inMilliseconds;
    debugPrint(
      'RUNTIME_UI first_install state=${status.state.name} '
      'abi=${status.abi} payload=${status.payloadId} '
      'install_ms=${status.installMs} open_to_audited_ms=$elapsed '
      'progress_frames=$progressSeen problem=${status.problem?.name} '
      'outside_apk=${audit?.outsideApk} shipped=${audit?.shipped} '
      'audit_ms=${audit?.millis} detail=${status.detail}',
    );
    expect(status.state, RuntimeState.ready, reason: status.detail);
    expect(status.installMs, isNotNull);
    expect(audit, isNotNull);
    expect(audit!.outsideApk, 0, reason: audit.report);
    expect(audit.truncated, isFalse);
    expect(audit.shipped, greaterThan(100));
    expect(status.info?.bootstrap, isNotNull);
    expect(progressSeen, greaterThan(0), reason: 'no progress reached Dart');

    // The status strip says so.
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('status_runtime')), findsWidgets);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
