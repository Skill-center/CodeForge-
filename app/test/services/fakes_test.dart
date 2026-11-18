import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/fakes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('honest availability fakes', () {
    test('terminal reports unavailable with a phase-accurate reason', () {
      final terminal = FakeTerminalService();
      expect(terminal.availability, TerminalAvailability.unavailable);
      expect(terminal.unavailableReason, contains('Phase 5'));
    });

    test('git summary is a labeled demo branch', () async {
      final git = FakeGitService();
      expect((await git.summary()).orThrow.branch, 'main');
    });
  });
}
