import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/fakes.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/memory_file_service.dart';

void main() {
  group('honest availability fakes', () {
    test('terminal reports unavailable with a phase-accurate reason', () {
      final terminal = FakeTerminalService();
      expect(terminal.availability, TerminalAvailability.unavailable);
      expect(terminal.unavailableReason, contains('Phases 4–5'));
    });

    test('runtime reports notInstalled', () async {
      final runtime = FakeRuntimeService();
      expect((await runtime.state()).orThrow, RuntimeState.notInstalled);
    });

    test('git summary is a labeled demo branch', () async {
      final git = FakeGitService();
      expect((await git.summary()).orThrow.branch, 'main');
    });

    test('search matches demo filenames', () async {
      final search = FakeSearchService(MemoryFileService());
      final hits = (await search.searchFiles('main')).orThrow;
      expect(hits, ['main.js']);
      expect((await search.searchFiles('')).orThrow, isEmpty);
    });
  });
}
