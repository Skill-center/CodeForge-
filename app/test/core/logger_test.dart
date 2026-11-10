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

    test('content:// URIs keep only their authority', () {
      final redacted = redactFields({
        'uri':
            'content://com.android.externalstorage.documents/tree/'
            'primary%3ADocuments%2Fsecret-project',
        'error':
            'PlatformException(denied, content://media/external/file/42 '
            'is gone, null)',
        'count': 2,
      });
      expect(
        redacted['uri'],
        'content://com.android.externalstorage.documents/…',
      );
      expect(
        redacted['error'],
        'PlatformException(denied, content://media/… is gone, null)',
      );
      expect(redacted['count'], 2);
      expect('$redacted', isNot(contains('secret-project')));
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

    test('added sinks get every record after the console sink', () {
      final order = <String>[];
      final logger = CfLogger(sink: (r) => order.add('console ${r.event}'));
      void file(LogRecord r) => order.add('file ${r.event}');
      void other(LogRecord r) => order.add('other ${r.event}');
      logger
        ..addSink(file)
        ..addSink(other)
        ..info('test', 'one');
      expect(order, ['console one', 'file one', 'other one']);

      order.clear();
      expect(logger.removeSink(file), isTrue);
      expect(logger.removeSink(file), isFalse);
      logger
        ..sink = null
        ..warn('test', 'two', fields: {'password': 'hunter2'});
      expect(order, ['other two']);
      expect(logger.records.last.fields['password'], '[redacted]');
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
