/// Gate G3, part B (Phase 4 W3): the warm start. Part A
/// (runtime_a_test.dart) installed the runtime; the gate then killed the
/// process. Here the app comes back over the same files, the workbench
/// starts the runtime, and nothing is extracted: the install marker
/// matches this APK's payload, the executables' links are checked, and the
/// audit runs again. Then gate G4 (Phase 4 W4): Settings → Linux runtime
/// probes the tools through RuntimeHost, each its pinned version, and a
/// command runs end to end. app/tool/ci/emulator_gate.sh reads the
/// RUNTIME_UI lines.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/router.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/features/settings/runtime_screen.dart';
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

    // G4: the tools reach the Flutter UI through RuntimeHost, each its
    // package's pinned version.
    container.read(routerProvider).go('/settings/runtime');
    await tester.pumpAndSettle();
    expect(find.byType(RuntimeScreen), findsOneWidget);
    await pumpUntil(
      tester,
      () {
        final tools = container.read(runtimeToolsProvider);
        return tools.tools != null && !tools.probing;
      },
      what: 'the tool probes',
      timeout: const Duration(minutes: 4),
    );
    final probes = container.read(runtimeToolsProvider).tools!;
    final versions = probes.tools
        .map((tool) => '${tool.tool}=${tool.version}/${tool.health.name}')
        .join(' ');
    debugPrint(
      'RUNTIME_UI tools ok=${probes.okCount} of=${probes.tools.length} '
      'ms=${probes.millis} $versions',
    );
    for (final tool in probes.tools) {
      debugPrint('RUNTIME_UI tool ${tool.tool} detail=${tool.detail}');
    }
    expect(probes.failure, isNull);
    expect(probes.tools.map((tool) => tool.tool), [
      'node',
      'python',
      'git',
      'bash',
      'perl',
      'ruby',
      'rg',
    ]);
    for (final tool in probes.tools) {
      expect(tool.health, ToolHealth.ok, reason: '${tool.tool}: ${tool.detail}');
    }
    // What the page shows: the summary, then each tool with its version.
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('runtime_tools')),
      200,
      scrollable: list,
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('All 7 tools are their pinned versions'),
      findsOneWidget,
    );
    for (final tool in probes.tools) {
      final row = find.byKey(ValueKey('runtime_tool_${tool.tool}'));
      await tester.scrollUntilVisible(row, 200, scrollable: list);
      expect(
        find.descendant(
          of: row,
          matching: find.text('${tool.tool} ${tool.version}'),
        ),
        findsOneWidget,
      );
    }

    // A command end to end: Dart, Pigeon, RuntimeHost, the launcher, node.
    final result = await container
        .read(runtimeControllerProvider.notifier)
        .exec('node', ['-e', 'console.log(6 * 7)']);
    final value = (result as Ok<ExecResult>).value;
    debugPrint(
      'RUNTIME_UI exec failure=${value.failure?.name} exit=${value.exitCode} '
      'stdout=${value.stdout.trim()} ms=${value.durationMs} '
      'detail=${value.detail}',
    );
    expect(value.failure, isNull, reason: value.detail);
    expect(value.exitCode, 0, reason: value.stderr);
    expect(value.stdout, '42\n');
  }, timeout: const Timeout(Duration(minutes: 14)));
}
