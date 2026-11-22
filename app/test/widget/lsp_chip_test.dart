/// The language server chip (Phase 6 W4): the status strip names the
/// active file's server and its state (ready, restarting, off with why),
/// offers Restart once it gave up, and shows nothing where no host can run
/// servers; the tooltip's words.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/design_system/components/feedback.dart';
import 'package:codeforge/design_system/tokens/icons.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_runtime_service.dart';
import '../support/scripted_lsp_service.dart';
import 'test_harness.dart';

const ValueKey<String> _chipKey = ValueKey('status_lsp');

CfStatusChip _chip(WidgetTester tester) =>
    tester.widget<CfStatusChip>(find.byKey(_chipKey));

DocumentController _documents(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(WorkbenchScreen)),
      listen: false,
    ).read(documentControllerProvider.notifier);

/// The workbench over a scripted host ([host]) and a ready runtime; with
/// [runtime] false the runtime's host never answers, so it is never ready.
Future<ScriptedLspService?> _pump(
  WidgetTester tester, {
  bool host = true,
  bool runtime = true,
}) async {
  setSurface(tester, 1280, 800);
  final lsp = host ? ScriptedLspService() : null;
  await tester.pumpWidget(
    TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
      runtime: FakeRuntimeService(state: RuntimeState.ready, answers: runtime),
      lsp: lsp,
    ).app(),
  );
  await tester.pumpAndSettle();
  return lsp;
}

void main() {
  testWidgets("the chip names the active file's server, and how it is", (
    tester,
  ) async {
    final lsp = (await _pump(tester))!;
    await _documents(tester).open('app.py');
    await tester.pumpAndSettle();
    expect(_chip(tester).label, 'Pyright: ready');
    expect(_chip(tester).onTap, isNull);
    expect(_chip(tester).tooltip, 'Pyright is analysing this file as you type');

    lsp.crash(lsp.latest);
    await tester.pump();
    await tester.pump();
    expect(_chip(tester).label, 'Pyright: restarting');
    expect(
      _chip(tester).tooltip,
      'Pyright is restarting: Pyright was ended by signal 9',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(_chip(tester).label, 'Pyright: ready');

    await _documents(tester).open('main.js');
    await tester.pumpAndSettle();
    expect(_chip(tester).label, 'TypeScript: ready');
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('a server that gave up is offered for Restart', (tester) async {
    final lsp = (await _pump(tester))!;
    await _documents(tester).open('app.py');
    await tester.pumpAndSettle();
    for (var crash = 0; crash < 4; crash++) {
      lsp.crash(lsp.latest);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    }
    expect(_chip(tester).label, 'Pyright: off');
    expect(_chip(tester).icon, CfIcons.restartAlt);
    expect(_chip(tester).tooltip, endsWith('Tap to restart.'));
    expect(lsp.starts, hasLength(4));
    await tester.tap(find.byKey(_chipKey));
    await tester.pumpAndSettle();
    expect(lsp.starts, hasLength(5));
    expect(_chip(tester).label, 'Pyright: ready');
    expect(_chip(tester).onTap, isNull);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('without the runtime the chip says so', (tester) async {
    final lsp = (await _pump(tester, runtime: false))!;
    await _documents(tester).open('app.py');
    await tester.pumpAndSettle();
    expect(_chip(tester).label, 'Pyright: off');
    expect(_chip(tester).tooltip, 'The Linux runtime is not ready');
    expect(lsp.starts, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('without a host there is no chip', (tester) async {
    await _pump(tester, host: false);
    await _documents(tester).open('app.py');
    await tester.pumpAndSettle();
    expect(find.byKey(_chipKey), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
  });

  test("the tooltip's words", () {
    expect(
      languageServerTooltip(LspServerId.pyright, LspStatus.off),
      'Pyright starts with a file it analyses',
    );
    expect(
      languageServerTooltip(
        LspServerId.typescript,
        const LspStatus(LspPhase.starting),
      ),
      'TypeScript is starting',
    );
    expect(
      languageServerTooltip(
        LspServerId.typescript,
        const LspStatus(LspPhase.analysing),
      ),
      'TypeScript is analysing the project',
    );
    expect(
      languageServerTooltip(
        LspServerId.pyright,
        const LspStatus(LspPhase.off, reason: 'It broke', canRestart: true),
      ),
      'It broke. Tap to restart.',
    );
  });
}
