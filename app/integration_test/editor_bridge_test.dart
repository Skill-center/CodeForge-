/// Phase 2 W2 on the CI emulator: the real, verified editor page in the
/// Android System WebView, talking to the real host over the real bridge.
/// Widget tests cover the host against a scripted page; this proves the
/// page, the JavaScript channel and the WebView hardening work together.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/editor_tabs_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp;

/// Pumps real time until [condition] holds (integration tests run live).
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('Timed out after ${timeout.inSeconds} s waiting for $what.');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('editor bridge: real page, edits, page restart, save', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await pumpRealApp(tester, prefs);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    final opened = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final host = container.read(editorHostProvider);

    // The verified page loads in the WebView and announces itself.
    await pumpUntil(
      tester,
      () =>
          host.status.phase == EditorHostPhase.ready ||
          host.status.phase == EditorHostPhase.failed,
      what: 'the editor page to start',
    );
    expect(
      host.status.phase,
      EditorHostPhase.ready,
      reason: host.status.message,
    );
    await pumpUntil(tester, () => host.syncs >= 1, what: 'the first sync');
    debugPrint(
      'editor-bridge: ready and synced ${opened.elapsedMilliseconds} ms '
      'after opening the workbench (engine ${host.status.engineVersion})',
    );

    final docId = container.read(editorTabsProvider).docIds['main.js']!;
    final original = host.textOf(docId)!;
    expect(host.versionOf(docId), 0);

    // An edit made in the page comes back as an incremental change.
    expect((await host.insert('// hi\n')).isOk, isTrue);
    await pumpUntil(
      tester,
      () => (host.versionOf(docId) ?? 0) > 0,
      what: 'doc.changed for the insert',
    );
    expect(host.textOf(docId), '// hi\n$original');
    final edited = (await host.snapshot(docId)).orThrow;
    expect(edited.text, host.textOf(docId));
    expect(edited.version, host.versionOf(docId));
    expect(host.resyncs, 0);
    await tester.pumpAndSettle();
    expect(
      container.read(editorTabsProvider).documents['main.js']!.dirty,
      isTrue,
    );

    // A page restart loses nothing: every document reopens from its shadow,
    // edits and version included.
    final versionBefore = host.versionOf(docId);
    await host.reloadPage();
    await pumpUntil(
      tester,
      () =>
          host.pageStarts >= 2 &&
          host.syncs >= 2 &&
          host.status.phase == EditorHostPhase.ready,
      what: 'the reloaded page to resync',
    );
    final restored = (await host.snapshot(docId)).orThrow;
    expect(restored.text, '// hi\n$original');
    expect(restored.version, versionBefore);
    expect(host.resyncs, 0);

    // Save writes what the editor holds.
    await container.read(editorTabsProvider.notifier).saveActive();
    await tester.pumpAndSettle();
    expect(
      container.read(editorTabsProvider).documents['main.js']!.dirty,
      isFalse,
    );
    expect(host.droppedMessages, 0);
    debugPrint(
      'editor-bridge: ok (page starts ${host.pageStarts}, syncs '
      '${host.syncs}, resyncs ${host.resyncs})',
    );
  });
}
