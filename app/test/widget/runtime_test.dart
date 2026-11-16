/// The sealed runtime in the app (Phase 4 W3, gate G3): opening a
/// workspace starts it, the status strip shows where it is, and Settings →
/// Linux runtime shows its payload, its timing, its size and its audit, and
/// reinstalls it.
library;

import 'package:codeforge/design_system/components/feedback.dart';
import 'package:codeforge/features/settings/runtime_screen.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_runtime_service.dart';
import 'test_harness.dart';

CfStatusChip _chip(WidgetTester tester) =>
    tester.widget<CfStatusChip>(find.byKey(const ValueKey('status_runtime')));

String? _subtitle(WidgetTester tester, String key) {
  final tile = find.byKey(ValueKey(key));
  final texts = find.descendant(of: tile, matching: find.byType(Text));
  return tester.widgetList<Text>(texts).map((text) => text.data).join('\n');
}

/// Settings, then its runtime row.
Future<void> _openRuntimePage(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('settings_runtime'));
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
  expect(find.byType(RuntimeScreen), findsOneWidget);
}

/// Scrolls the runtime page to [key].
Future<void> _scrollTo(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opening a workspace starts the runtime, warm when installed', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness();
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    expect(harness.runtime.starts, 0, reason: 'the install is lazy');

    await openDemoWorkspace(tester);
    expect(harness.runtime.starts, 1);
    expect(harness.runtime.current.state, RuntimeState.ready);
    final chip = _chip(tester);
    expect(chip.label, 'runtime');
    expect(chip.tooltip, 'Runtime ready');
  });

  testWidgets('the strip shows the install as it goes, then a failure', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final runtime = FakeRuntimeService(
      state: RuntimeState.notInstalled,
      installFails: RuntimeProblem.corrupt,
    );
    final harness = TestHarness(runtime: runtime);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await openDemoWorkspace(tester);
    expect(_chip(tester).label, 'runtime failed');
    expect(_chip(tester).tooltip, contains('Settings → Runtime'));

    runtime.moveTo(RuntimeState.installing, done: 6946, total: 13892);
    await tester.pump();
    expect(_chip(tester).label, 'installing 50%');
    expect(_chip(tester).tooltip, 'Installing the runtime: 6946 of 13892 files');
  });

  testWidgets('a build without a runtime says so', (tester) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness(
      runtime: FakeRuntimeService(state: RuntimeState.unavailable),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await openDemoWorkspace(tester);
    expect(_chip(tester).label, 'no runtime');
    expect(harness.runtime.current.state, RuntimeState.unavailable);
  });

  testWidgets('without a host the runtime is unavailable, not stuck', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness(runtime: FakeRuntimeService()..answers = false);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await openDemoWorkspace(tester);
    expect(_chip(tester).label, 'no runtime');
  });

  testWidgets('Settings names the runtime and opens its page', (tester) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(shell: const ShellState(lastRoute: '/settings'));
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    expect(
      _subtitle(tester, 'settings_runtime'),
      contains('Installed: it starts when you open a workspace'),
    );

    await _openRuntimePage(tester);
    expect(
      _subtitle(tester, 'runtime_status'),
      contains('Installed: it starts when you open a workspace'),
    );
    expect(
      _subtitle(tester, 'runtime_payload'),
      contains('Termux 2026.02.12-r1+apt.android-7'),
    );
    expect(_subtitle(tester, 'runtime_payload'), contains('112 packages'));
    expect(
      _subtitle(tester, 'runtime_versions'),
      'Tools in this payload\ngit 2.56.1 · python 3.14.10 · nodejs 26.13.1',
    );
    expect(find.byKey(const ValueKey('runtime_start')), findsOneWidget);
  });

  testWidgets('Install now starts it; the audit, the size and the timing show', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
      runtime: FakeRuntimeService(state: RuntimeState.notInstalled),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await _openRuntimePage(tester);

    await tester.tap(find.byKey(const ValueKey('runtime_start')));
    await tester.pumpAndSettle();
    expect(harness.runtime.starts, 1);
    expect(
      _subtitle(tester, 'runtime_status'),
      contains('Ready · every program comes from the app'),
    );
    expect(find.byKey(const ValueKey('runtime_reinstall')), findsOneWidget);

    await _scrollTo(tester, 'runtime_install_time');
    expect(_subtitle(tester, 'runtime_install_time'), contains('23.5 s'));

    await _scrollTo(tester, 'runtime_measure');
    await tester.tap(find.byKey(const ValueKey('runtime_measure')));
    await tester.pumpAndSettle();
    expect(harness.runtime.sizes, 1);
    expect(_subtitle(tester, 'runtime_size'), contains('583.0 MB in all'));
    expect(_subtitle(tester, 'runtime_size'), contains('13892 files'));

    await _scrollTo(tester, 'runtime_audit');
    expect(_subtitle(tester, 'runtime_audit'), contains('0 programs outside'));
    expect(_subtitle(tester, 'runtime_audit'), contains('534 programs from'));
    await tester.tap(find.byKey(const ValueKey('runtime_audit_again')));
    await tester.pumpAndSettle();
    expect(harness.runtime.audits, 1);
  });

  testWidgets('Reinstall asks first, and installs again only when told to', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(shell: const ShellState(lastRoute: '/settings'));
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await _openRuntimePage(tester);
    await tester.tap(find.byKey(const ValueKey('runtime_start')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('runtime_reinstall')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('runtime_reinstall_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('runtime_reinstall_cancel')));
    await tester.pumpAndSettle();
    expect(harness.runtime.reinstalls, 0);

    await tester.tap(find.byKey(const ValueKey('runtime_reinstall')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('runtime_reinstall_ok')));
    await tester.pumpAndSettle();
    expect(harness.runtime.reinstalls, 1);
    expect(harness.runtime.current.state, RuntimeState.ready);
    expect(
      _subtitle(tester, 'runtime_status'),
      contains('Ready · every program comes from the app'),
    );
  });

  testWidgets('a failed install says why, and keeps Reinstall', (tester) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
      runtime: FakeRuntimeService(
        state: RuntimeState.notInstalled,
        installFails: RuntimeProblem.corrupt,
      ),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await _openRuntimePage(tester);
    await tester.tap(find.byKey(const ValueKey('runtime_start')));
    await tester.pumpAndSettle();

    expect(
      _subtitle(tester, 'runtime_status'),
      contains('a file did not match its checksum, so nothing was kept'),
    );
    expect(
      _subtitle(tester, 'runtime_detail'),
      contains('digest differs: lib/python3.14/os.py'),
    );
    expect(find.byKey(const ValueKey('runtime_reinstall')), findsOneWidget);
    expect(find.byKey(const ValueKey('runtime_start')), findsNothing);
  });

  testWidgets('a program outside the app degrades it, and says so', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
      runtime: FakeRuntimeService(auditFindsOutside: true),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await _openRuntimePage(tester);
    await tester.tap(find.byKey(const ValueKey('runtime_start')));
    await tester.pumpAndSettle();

    expect(harness.runtime.current.state, RuntimeState.degraded);
    expect(
      _subtitle(tester, 'runtime_status'),
      contains('programs that did not come with the app were found'),
    );
    await _scrollTo(tester, 'runtime_audit');
    expect(_subtitle(tester, 'runtime_audit'), contains('1 program outside'));
  });

  testWidgets('the runtime report can be copied', (tester) async {
    setSurface(tester, 412, 915);
    final copied = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final arguments = call.arguments as Map<Object?, Object?>;
        copied.add(arguments['text']! as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final harness = TestHarness(shell: const ShellState(lastRoute: '/settings'));
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await _openRuntimePage(tester);
    await tester.tap(find.byKey(const ValueKey('runtime_start')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('runtime_copy_report')));
    await tester.pumpAndSettle();
    expect(find.text('Runtime report copied'), findsOneWidget);
    expect(copied, hasLength(1));
    expect(copied.single, contains('state: ready'));
    expect(copied.single, contains('payload: 0123456789abcdef'));
    expect(copied.single, contains('warm start: 12 ms'));
    expect(copied.single, contains('--- exec audit (412 ms)'));
  });

  test('the status lines and the report follow the host', () {
    const failed = RuntimeStatus(
      state: RuntimeState.failed,
      problem: RuntimeProblem.storage,
    );
    expect(runtimeStatusLine(failed), contains('Free some space'));
    expect(
      runtimeStatusLine(
        const RuntimeStatus(
          state: RuntimeState.installing,
          done: 1,
          total: 4,
        ),
      ),
      'Installing… 25% (1 of 4 files)',
    );
    expect(runtimeMegabytes(97867524), '97.9 MB');
    expect(runtimePrograms(1), '1 program');
    expect(runtimeReport(failed), contains('problem: storage'));
    expect(RuntimeProblem.fromCode('outside_apk'), RuntimeProblem.outsideApk);
    expect(RuntimeProblem.fromCode('who knows'), RuntimeProblem.unexpected);
    expect(RuntimeState.fromCode('degraded'), RuntimeState.degraded);
    expect(RuntimeState.fromCode('later'), RuntimeState.unknown);
  });

  test('the payload info is read from the host JSON, or not at all', () {
    final info = RuntimePayloadInfo.parse(
      '{"bootstrap": "2026.02.12-r1+apt.android-7", "packages": 112, '
      '"resolvedAt": "2026-11-13T09:43:19Z", '
      '"core": [{"package": "git", "version": "2.56.1"}, {"bad": 1}]}',
    );
    expect(info!.bootstrap, '2026.02.12-r1+apt.android-7');
    expect(info.packages, 112);
    expect(info.core.single.name, 'git');
    expect(info.resolvedAt, '2026-11-13T09:43:19Z');
    expect(RuntimePayloadInfo.parse(null), isNull);
    expect(RuntimePayloadInfo.parse('not json'), isNull);
    expect(RuntimePayloadInfo.parse('[1, 2]'), isNull);
    expect(RuntimePayloadInfo.parse('{"packages": 3}'), isNull);
  });
}
