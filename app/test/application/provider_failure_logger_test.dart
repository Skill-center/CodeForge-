/// The ProviderObserver that logs provider failures (Phase 3 W6, an owner
/// item of 2026-11-11): through the logger, with its redaction.
library;

import 'dart:async';

import 'package:codeforge/application/provider_failure_logger.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _treeUri =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments';

/// A container whose failures go to [logger], and which never tries a
/// failed provider again (Riverpod's default would, on a timer).
ProviderContainer _container(CfLogger logger) {
  final container = ProviderContainer(
    observers: [ProviderFailureLogger(logger: logger)],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  return container;
}

List<LogRecord> _failures(CfLogger logger) =>
    logger.records.where((record) => record.tag == 'provider').toList();

void main() {
  test('a provider that throws while building is logged as an error', () {
    final logger = CfLogger();
    final container = _container(logger);
    final broken = Provider<int>(
      (ref) => throw StateError('no folder at $_treeUri/document/x'),
      name: 'brokenProvider',
    );

    expect(() => container.read(broken), throwsA(anything));

    final record = _failures(logger).single;
    expect(record.level, LogLevel.error);
    expect(record.event, 'failed');
    expect(record.fields['provider'], 'brokenProvider');
    expect('${record.fields['error']}', contains('no folder at'));
    // The logger's redaction: a document URI keeps only its authority.
    expect(
      '${record.fields['error']}',
      contains('content://com.android.externalstorage.documents/…'),
    );
    expect('${record.fields['error']}', isNot(contains('primary%3A')));
    expect(record.fields.containsKey('at'), isTrue);
    expect(
      record.fields['at'],
      isNull,
      reason: "the code that threw is this test's, not the app's",
    );
  });

  test('a future that fails is logged once it fails', () async {
    final logger = CfLogger();
    final container = _container(logger);
    final failing = FutureProvider<int>((ref) async {
      await Future<void>.delayed(Duration.zero);
      throw const FormatException('bad listing');
    }, name: 'listingProvider');

    await expectLater(
      container.read(failing.future),
      throwsA(anything),
    );

    final record = _failures(logger).single;
    expect(record.fields['provider'], 'listingProvider');
    expect('${record.fields['error']}', contains('bad listing'));
  });

  test('a stream that ends in an error is logged', () async {
    final logger = CfLogger();
    final container = _container(logger);
    final failNow = Completer<void>();
    final events = StreamProvider<int>((ref) async* {
      yield 1;
      await failNow.future;
      throw StateError('watch lost');
    }, name: 'eventsProvider');
    final subscription = container.listen(events, (_, _) {});
    addTearDown(subscription.close);

    await pumpEventQueue();
    expect(container.read(events).value, 1);
    expect(_failures(logger), isEmpty, reason: 'a value is not a failure');

    failNow.complete();
    await pumpEventQueue();

    final record = _failures(logger).single;
    expect(record.fields['provider'], 'eventsProvider');
    expect('${record.fields['error']}', contains('watch lost'));
  });

  test('a notifier whose build throws is named by its type', () {
    final logger = CfLogger();
    final container = _container(logger);

    expect(() => container.read(_brokenNotifier), throwsA(anything));

    final record = _failures(logger).single;
    expect('${record.fields['provider']}', contains('_BrokenNotifier'));
    expect('${record.fields['error']}', contains('not today'));
  });

  test('providers that work log nothing', () {
    final logger = CfLogger();
    final container = _container(logger);
    final fine = Provider<int>((ref) => 42);

    expect(container.read(fine), 42);
    expect(_failures(logger), isEmpty);
  });

  test('the first frame of the app is cut from a stack trace', () {
    final stack = StackTrace.fromString(
      '#0      Object.noSuchMethod (dart:core-patch/object_patch.dart:38:5)\n'
      '#1      FileIndexController._walk '
      '(package:codeforge/application/file_index.dart:350:12)\n'
      '#2      main (package:codeforge/main.dart:9:3)\n',
    );
    expect(appFrameOf(stack), 'package:codeforge/application/file_index.dart:350:12');
    expect(
      appFrameOf(StackTrace.fromString('#0 main (dart:core/x.dart:1:1)')),
      isNull,
    );
  });
}

final class _BrokenNotifier extends Notifier<int> {
  @override
  int build() => throw StateError('not today');
}

final _brokenNotifier = NotifierProvider<_BrokenNotifier, int>(
  _BrokenNotifier.new,
);
