/// The workbench over a scripted language server with W5's features
/// (Phase 6 W5), for the language features' widget tests and goldens.
library;

import 'dart:async';

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_runtime_service.dart';
import '../support/memory_library_files.dart';
import '../support/scripted_lsp_service.dart';
import 'test_harness.dart';

/// The demo project's folder, as the scripted host names it.
const String lspDemoRoot = '$scriptedFilesRoot/workspaces/demo';

/// A file in Pyright's stubs, under the scripted server's folder.
const String lspStub =
    '/rt/codeforge/lsp/pyright/node_modules/pyright/dist/typeshed-fallback/'
    'stdlib/builtins.pyi';

Map<String, Object?> lspRange(int sl, int sc, int el, int ec) => {
  'start': {'line': sl, 'character': sc},
  'end': {'line': el, 'character': ec},
};

/// A diagnostic as Pyright publishes it: an error (1) or a warning (2).
Map<String, Object?> lspProblem(int line, int from, int to, int severity) => {
  'range': lspRange(line, from, line, to),
  'severity': severity,
  'message': severity == 1 ? '"greet" is not defined' : '"os" is not accessed',
  'source': 'Pyright',
};

/// The workbench over a scripted host with W5's features and a ready
/// runtime, [files] in the project.
Future<(TestHarness, ScriptedLspService)> pumpWithServers(
  WidgetTester tester, {
  Map<String, String> files = const {},
  double width = 1280,
  double height = 800,
  AppSettings settings = const AppSettings(welcomeSeen: true),
  MemoryLibraryFiles? library,
}) async {
  setSurface(tester, width, height);
  final lsp = ScriptedLspService()
    ..capabilities = ScriptedLspService.featureCapabilities;
  final harness = TestHarness(
    settings: settings,
    shell: const ShellState(lastRoute: '/workspace'),
    runtime: FakeRuntimeService(state: RuntimeState.ready),
    lsp: lsp,
    libraryFiles: library,
  );
  for (final MapEntry(:key, :value) in files.entries) {
    harness.files.putText(key, value);
  }
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  return (harness, lsp);
}

/// Opens [path] in the workbench pumped by [pumpWithServers].
Future<void> openFile(WidgetTester tester, String path) async {
  unawaited(
    ProviderScope.containerOf(
      tester.element(find.byType(WorkbenchScreen)),
      listen: false,
    ).read(documentControllerProvider.notifier).open(path),
  );
  await tester.pumpAndSettle();
}

/// Pyright publishes [items] for [path].
Future<void> publish(
  WidgetTester tester,
  ScriptedLspService lsp,
  String path,
  List<Map<String, Object?>> items,
) async {
  lsp.deliver(lsp.handleOf(LspServerId.pyright), {
    'jsonrpc': '2.0',
    'method': 'textDocument/publishDiagnostics',
    'params': {'uri': 'file://$lspDemoRoot/$path', 'diagnostics': items},
  });
  await tester.pumpAndSettle();
}

/// The page asks as a long press or F2 would.
Future<void> pageAsks(
  WidgetTester tester,
  TestHarness harness,
  String type,
  int pos,
) async {
  final page = harness.editorSurface;
  final docId = page.activeDocId!;
  unawaited(
    page.request(type, {
      'docId': docId,
      'version': page.documents[docId]!.version,
      'pos': pos,
    }),
  );
  await tester.pumpAndSettle();
}
