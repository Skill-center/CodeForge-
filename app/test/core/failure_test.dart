import 'package:codeforge/core/errors/failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Result', () {
    test('Ok carries a value', () {
      const Result<int> result = Ok(42);
      expect(result.isOk, isTrue);
      expect(result.valueOrNull, 42);
      expect(result.failureOrNull, isNull);
      expect(result.orThrow, 42);
    });

    test('Err carries a typed failure', () {
      const Result<int> result = Err(StorageFailure('disk full'));
      expect(result.isOk, isFalse);
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull, isA<StorageFailure>());
      expect(() => result.orThrow, throwsA(isA<StorageFailure>()));
    });

    test('failure kinds are stable identifiers', () {
      expect(const StorageFailure('x').kind, 'storage');
      expect(const BridgeFailure('x').kind, 'bridge');
      expect(const RuntimeFailure('x').kind, 'runtime');
      expect(const ProcessFailure('x', exitCode: 137).kind, 'process');
      expect(const UnexpectedFailure('x').kind, 'unexpected');
    });

    test('ProcessFailure preserves exit code for diagnostics', () {
      const failure = ProcessFailure('killed', exitCode: 137);
      expect(failure.exitCode, 137);
      expect(failure.toString(), contains('process'));
      expect(failure.toString(), contains('killed'));
    });

    test('switch exhaustiveness over Result', () {
      const Result<String> ok = Ok('hello');
      final rendered = switch (ok) {
        Ok<String>(:final value) => 'ok:$value',
        Err<String>(:final failure) => 'err:${failure.kind}',
      };
      expect(rendered, 'ok:hello');
    });
  });
}
