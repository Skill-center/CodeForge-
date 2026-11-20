/// The sealed runtime in the app (Phase 4 W3, gate G3): opening a
/// workspace starts it, the status strip shows where it is, and Settings →
/// Linux runtime shows its payload, its timing, its size and its audit, and
/// reinstalls it. Since W4 (gate G4) the page also probes the tools, each
/// against its pin, and says which languages the runtime can execute.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/editor/capabilities.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/design_system/components/feedback.dart';
import 'package:codeforge/features/settings/runtime_screen.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Scrolls the runtime page to [key], down unless [up].
Future<void> _scrollTo(
  WidgetTester tester,
  String key, {
  bool up = false,
}) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    up ? -200 : 200,
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
    // The event, then the chip's rebuild in the frame after it.
    await tester.pumpAndSettle();
    expect(_chip(tester).label, 'installing 50%');
    expect(
      _chip(tester).tooltip,
      'Installing the runtime: 6946 of 13892 files',
    );
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
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
    );
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

  testWidgets(
    'Install now starts it; the audit, the size and the timing show',
    (tester) async {
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
      expect(
        _subtitle(tester, 'runtime_audit'),
        contains('0 programs outside'),
      );
      expect(_subtitle(tester, 'runtime_audit'), contains('534 programs from'));
      await tester.tap(find.byKey(const ValueKey('runtime_audit_again')));
      await tester.pumpAndSettle();
      expect(harness.runtime.audits, 1);
    },
  );

  testWidgets('Reinstall asks first, and installs again only when told to', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
    );
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
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
    );
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

  testWidgets('the tools are probed once it is ready, each against its pin', (
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

    // Nothing to probe yet, and nothing executable yet.
    await _scrollTo(tester, 'runtime_languages');
    expect(harness.runtime.toolProbes, 0);
    expect(
      _subtitle(tester, 'runtime_tools'),
      contains('Checked once it is ready'),
    );
    expect(
      _subtitle(tester, 'runtime_languages'),
      'JavaScript, Python, shell scripts, Ruby and Perl\n'
      'Run runs them once the runtime is ready',
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('runtime_start')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('runtime_start')));
    await tester.pumpAndSettle();
    expect(harness.runtime.current.state, RuntimeState.ready);
    expect(harness.runtime.toolProbes, 1, reason: 'probed once it is ready');

    await _scrollTo(tester, 'runtime_tools');
    expect(
      _subtitle(tester, 'runtime_tools'),
      contains('All 7 tools are their pinned versions'),
    );
    // Each tool's line is read where it shows: the page builds only what
    // is near the screen.
    final lines = <String, String>{};
    for (final tool in FakeRuntimeService.pinnedTools) {
      await _scrollTo(tester, 'runtime_tool_${tool.tool}');
      lines[tool.tool] = _subtitle(tester, 'runtime_tool_${tool.tool}');
    }
    expect(lines['node'], 'node 26.13.1\nnodejs 26.13.1, as pinned');
    // perl's package revision is not part of the version perl reports.
    expect(lines['perl'], 'perl 5.44.0\nperl 5.44.0-1, as pinned');
    expect(lines['rg'], 'rg 15.2.0\nripgrep 15.2.0, as pinned');
    await _scrollTo(tester, 'runtime_languages');
    expect(
      _subtitle(tester, 'runtime_languages'),
      'JavaScript, Python, shell scripts, Ruby and Perl\n'
      'Run runs them here, with node, python, bash, ruby, perl',
    );
  });

  testWidgets('a tool that is not its pinned version, or fails, says so', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final runtime = FakeRuntimeService(state: RuntimeState.ready)
      ..toolAnswers = [
        for (final tool in FakeRuntimeService.pinnedTools)
          switch (tool.tool) {
            'python' => const RuntimeTool(
              tool: 'python',
              packageName: 'python',
              version: '3.13.0',
              pinned: '3.14.10',
              health: ToolHealth.mismatch,
            ),
            'ruby' => const RuntimeTool(
              tool: 'ruby',
              packageName: 'ruby',
              pinned: '4.0.9',
              health: ToolHealth.failed,
              detail: 'exit 1: cannot load such file -- rubygems',
            ),
            _ => tool,
          },
      ];
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
      runtime: runtime,
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await _openRuntimePage(tester);
    expect(runtime.toolProbes, 1);

    await _scrollTo(tester, 'runtime_tools');
    expect(
      _subtitle(tester, 'runtime_tools'),
      contains('5 of 7 tools are their pinned versions'),
    );
    await _scrollTo(tester, 'runtime_tool_python');
    expect(
      _subtitle(tester, 'runtime_tool_python'),
      'python 3.13.0\nPinned python 3.14.10, found 3.13.0',
    );
    await _scrollTo(tester, 'runtime_tool_ruby');
    expect(
      _subtitle(tester, 'runtime_tool_ruby'),
      'ruby\nFailed: exit 1: cannot load such file -- rubygems',
    );

    // Check again: the tools are probed again.
    await _scrollTo(tester, 'runtime_tools', up: true);
    await tester.tap(find.byKey(const ValueKey('runtime_tools_check')));
    await tester.pumpAndSettle();
    expect(runtime.toolProbes, 2);
  });

  testWidgets('commands wait for the runtime, then run', (tester) async {
    setSurface(tester, 1280, 800);
    final runtime = FakeRuntimeService()
      ..onExec = (program, arguments) => ExecResult(
        exitCode: 0,
        stdout: '$program ${arguments.join(' ')}\n',
        stdoutBytes: 12,
      );
    final harness = TestHarness(runtime: runtime);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final controller = container.read(runtimeControllerProvider.notifier);

    final early = await controller.exec('node', ['-v']);
    expect((early as Ok<ExecResult>).value.failure, ExecFailure.notReady);

    await openDemoWorkspace(tester);
    final result = await controller.exec('node', ['-v']);
    final value = (result as Ok<ExecResult>).value;
    expect(value.succeeded, isTrue);
    expect(value.stdout, 'node -v\n');
    expect(runtime.commands, hasLength(2));
  });

  test('the language chip says what the runtime can do with a language', () {
    expect(
      languageCapabilityTooltip(capabilitiesOf('python', runtimeReady: true)),
      'Python: Run uses python in the Linux runtime',
    );
    expect(
      languageCapabilityTooltip(
        capabilitiesOf(shellLanguage, runtimeReady: false),
      ),
      'Shell scripts: Run needs the Linux runtime, which is not ready',
    );
    expect(
      languageCapabilityTooltip(capabilitiesOf('markdown', runtimeReady: true)),
      isNull,
    );
    expect(languageCapabilityTooltip(null), isNull);
  });

  test('the tools in the report, and their lines', () {
    const tools = RuntimeTools(
      tools: FakeRuntimeService.pinnedTools,
      millis: 455,
    );
    final report = runtimeReport(
      const RuntimeStatus(state: RuntimeState.ready),
      tools: tools,
    );
    expect(report, contains('--- tools (455 ms)'));
    expect(report, contains('perl: 5.44.0 (pinned 5.44.0-1) ok'));
    expect(tools.allOk, isTrue);
    expect(
      runtimeToolLine(
        const RuntimeTool(
          tool: 'git',
          packageName: 'git',
          health: ToolHealth.missing,
        ),
      ),
      'Not in this runtime',
    );
    expect(
      runtimeLanguagesLine(),
      'JavaScript, Python, shell scripts, Ruby and Perl',
    );
    expect(ToolHealth.fromCode('mismatch'), ToolHealth.mismatch);
    expect(ToolHealth.fromCode('later'), ToolHealth.unavailable);
    expect(ExecFailure.fromCode('timed_out'), ExecFailure.timedOut);
    expect(ExecFailure.fromCode(null), isNull);
    expect(ExecFailure.fromCode('who knows'), ExecFailure.launchFailed);
  });

  test('the status lines and the report follow the host', () {
    const failed = RuntimeStatus(
      state: RuntimeState.failed,
      problem: RuntimeProblem.storage,
    );
    expect(runtimeStatusLine(failed), contains('Free some space'));
    expect(
      runtimeStatusLine(
        const RuntimeStatus(state: RuntimeState.installing, done: 1, total: 4),
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
