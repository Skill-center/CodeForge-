import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/fakes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('honest availability fakes', () {
    test('terminal reports unavailable, and says what it needs', () {
      final terminal = FakeTerminalService();
      expect(terminal.availability, TerminalAvailability.unavailable);
      expect(terminal.unavailableReason, contains('on Android'));
    });

    test('git reports unavailable, and runs nothing', () async {
      final git = FakeGitService();
      expect(git.available, isFalse);
      final status = await git.status('demo');
      expect(status.isOk, isFalse);
      expect(
        (status.failureOrNull! as GitFailure).problem,
        GitProblem.unavailable,
      );
      expect(status.failureOrNull!.message, contains('on Android'));
    });
  });
}
