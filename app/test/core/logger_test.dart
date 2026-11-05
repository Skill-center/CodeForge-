import 'package:codeforge/core/logging/logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('redaction', () {
    test('redacts secret-looking field names', () {
      final redacted = redactFields({
        'token': 'ghp_abc123',
        'api_key': 'sk-xyz',
        'password': 'hunter2',
        'Authorization': 'Bearer abc',
        'ssh_key': 'PRIVATE',
        'path': '/home/user/file.dart',
        'count': 3,
      });
      expect(redacted['token'], '[redacted]');
      expect(redacted['api_key'], '[redacted]');
      expect(redacted['password'], '[redacted]');
      expect(redacted['Authorization'], '[redacted]');
      expect(redacted['ssh_key'], '[redacted]');
      expect(redacted['path'], '/home/user/file.dart');
      expect(redacted['count'], 3);
    });

    test('non-secret fields pass through untouched', () {
      final redacted = redactFields({'event': 'boot', 'ms': 120});
      expect(redacted, {'event': 'boot', 'ms': 120});
    });
  });

  group('ring buffer', () {
    test('keeps at most capacity records, oldest evicted', () {
      final logger = CfLogger(capacity: 3);
      for (var i = 0; i < 5; i++) {
        logger.info('test', 'event_$i');
      }
      expect(logger.records.length, 3);
      expect(logger.records.first.event, 'event_2');
      expect(logger.records.last.event, 'event_4');
    });

    test('sink receives redacted records', () {
      final received = <LogRecord>[];
      final logger = CfLogger(sink: received.add);
      logger.warn('auth', 'login', fields: {'token': 'secret-value'});
      expect(received, hasLength(1));
      expect(received.single.fields['token'], '[redacted]');
      expect(received.single.render(), isNot(contains('secret-value')));
    });

    test('render includes level, tag and event', () {
      final logger = CfLogger();
      logger.error('runtime', 'install_failed', fields: {'code': 1});
      final rendered = logger.records.single.render();
      expect(rendered, contains('[error]'));
      expect(rendered, contains('runtime/install_failed'));
      expect(rendered, contains('code=1'));
    });
  });
}
