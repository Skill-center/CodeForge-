/// Search on a phone (Phase 4 W6, the figures behind G8's budget): the
/// gate's 10,000-file project, searched by the runtime's ripgrep.
///
/// Firebase Test Lab runs it with no computer attached, after the session
/// store's timings, in the same entrypoint (sync_modes_test.dart calls
/// [phoneSearchTests]): the Test Lab job builds one Dart entrypoint into its
/// test app. The gate's search test (search_test.dart) needs Android's folder
/// picker, which only the gate's computer can answer, so the folder scan is
/// timed there alone. The result is printed as numbered
/// CODEFORGE_SEARCH_JSON lines, which the job reads back from the device log
/// (tool/ci/gate_results.py). The counts are checked exactly; the times are
/// recorded, never judged here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/application/search/search_controller.dart';
import 'package:codeforge/application/workspace_switcher.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/search/search_models.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kProfileMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// The gate's project: 10 × 10 folders of 100 files (search_test.dart).
const int _files = 10 * 10 * 100;

int _median(List<int> values) => ([...values]..sort())[values.length ~/ 2];

/// A project file as the gate writes it: on f07 a needle, on f08 needles.
String _content(int m, int s, int f) {
  final name = 'f${f.toString().padLeft(2, '0')}';
  final out = StringBuffer('// m$m/s$s/$name\n')
    ..write("export const id = 'm$m-s$s-$name';\n");
  if (f == 7) {
    out.write("const marker = 'needle';\n");
  } else if (f == 8) {
    out.write("const marker = 'needles';\n");
  }
  return out.toString();
}

void phoneSearchTests() {
  testWidgets(
    'search: ripgrep on a 10,000-file project, on a phone',
    timeout: const Timeout(Duration(minutes: 12)),
    (tester) async {
      final clock = Stopwatch()..start();
      final projects = Directory(await projectsRootPath());
      if (projects.existsSync()) {
        projects.deleteSync(recursive: true);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await pumpRealApp(tester, prefs);
      await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CodeForgeApp)),
        listen: false,
      );
      // The workbench starts the runtime, as it does for the user.
      await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('explore_demo')));
      await tester.pump();

      final switcher = container.read(workspaceSwitcherProvider);
      final created = await switcher.createProject('phone10k');
      final project = created.valueOrNull;
      expect(project, isNotNull, reason: 'create the project: $created');
      final root = '${projects.path}/${project!.folder}';
      final fill = Stopwatch()..start();
      for (var m = 0; m < 10; m++) {
        for (var s = 0; s < 10; s++) {
          final folder = Directory('$root/m$m/s$s')
            ..createSync(recursive: true);
          await Future.wait([
            for (var f = 0; f < 100; f++)
              File(
                '${folder.path}/f${f.toString().padLeft(2, '0')}.js',
              ).writeAsString(_content(m, s, f)),
          ]);
        }
      }
      fill.stop();
      final opened = await switcher.open(project);
      expect(opened.isOk, isTrue, reason: 'open the project: $opened');
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () {
          final status = container.read(runtimeControllerProvider);
          return (status.usable && !status.auditing) ||
              status.state == RuntimeState.failed ||
              status.state == RuntimeState.unavailable;
        },
        what: 'the runtime to be ready',
        timeout: const Duration(minutes: 5),
      );
      final runtime = container.read(runtimeControllerProvider);
      expect(runtime.state, RuntimeState.ready, reason: runtime.detail);

      final search = container.read(searchControllerProvider.notifier);
      Future<SearchState> run(SearchQuery query) async {
        search.search(query);
        await pumpUntil(
          tester,
          () =>
              container.read(searchControllerProvider).phase ==
              SearchPhase.finished,
          what: 'the search for ${query.text}',
          timeout: const Duration(minutes: 3),
        );
        return container.read(searchControllerProvider);
      }

      Map<String, Object?> figures(SearchState state) => {
        'engine': state.summary!.engine.name,
        'outcome': state.summary!.outcome.name,
        'files': state.files.length,
        'lines': state.lines,
        'firstMs': state.firstResultMs,
        'allMs': state.elapsedMs,
        'hostFirstMs': state.summary!.firstResultMs,
        'hostAllMs': state.summary!.elapsedMs,
      };

      final timed = <SearchState>[];
      for (var i = 0; i < 3; i++) {
        timed.add(await run(const SearchQuery(text: 'needle')));
      }
      for (final state in timed) {
        expect(state.summary!.engine, SearchEngine.ripgrep);
        expect(state.summary!.outcome, SearchOutcome.done);
        expect(state.files.length, 200);
      }
      final word = await run(
        const SearchQuery(text: 'needle', wholeWord: true),
      );
      expect(word.files.length, 100);
      final regex = await run(
        const SearchQuery(text: r"id = 'm[0-4]-s0-f\d+'", regex: true),
      );
      expect(regex.files.length, 500);
      final capped = await run(
        const SearchQuery(text: '^export const id', regex: true),
      );
      expect(capped.summary!.outcome, SearchOutcome.limit);
      expect(capped.lines, _files);

      int median(int? Function(SearchState) of) =>
          _median([for (final s in timed) of(s) ?? -1]);
      final json = jsonEncode({
        'test': 'phone_search',
        // The Test Lab job's build: debug until Phase 5 W6, profile since.
        'build': kDebugMode
            ? 'debug'
            : kProfileMode
            ? 'profile'
            : 'release',
        'files': _files,
        'writeMs': fill.elapsedMilliseconds,
        'needle': {
          'firstMs': median((s) => s.firstResultMs),
          'allMs': median((s) => s.elapsedMs),
          'hostFirstMs': median((s) => s.summary!.firstResultMs),
          'hostAllMs': median((s) => s.summary!.elapsedMs),
          'runs': [for (final s in timed) figures(s)],
        },
        'wholeWord': figures(word),
        'regex': figures(regex),
        'cap': figures(capped),
        'ms': clock.elapsedMilliseconds,
      });
      // Numbered lines of at most 600 characters, as the store's timings,
      // straight to the device log: debugPrint is throttled, and the test
      // could end before its queue drains (folder_gate.dart does the same).
      const size = 600;
      final parts = (json.length + size - 1) ~/ size;
      for (var part = 0; part < parts; part++) {
        final end = (part + 1) * size;
        Zone.root.print(
          'CODEFORGE_SEARCH_JSON ${part + 1}/$parts '
          '${json.substring(part * size, end > json.length ? json.length : end)}',
        );
      }
      projects.deleteSync(recursive: true);
    },
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  phoneSearchTests();
}
