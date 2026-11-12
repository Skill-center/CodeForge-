/// About → Recent logs → Save (Phase 3 W4): the log files' text, redacted
/// as it was logged, goes to a new file the user makes in Android's
/// create-document picker (the storage broker's `saveDocument`).
library;

import 'dart:convert';

import 'package:codeforge/application/logs.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/features/settings/about_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_storage_broker.dart';
import 'test_harness.dart';

Future<void> _openLogs(WidgetTester tester, FakeStorageBroker broker) async {
  await tester.pumpWidget(TestHarness(broker: broker).wrap(const AboutScreen()));
  await tester.pumpAndSettle();
  final tile = find.text('Recent logs');
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('logs_save')));
  await tester.pumpAndSettle();
}

void main() {
  group('saveLogs', () {
    test('suggests a name from the local time', () {
      expect(
        savedLogName(DateTime(2026, 11, 2, 5, 3)),
        'codeforge-logs-20261102-0503.txt',
      );
    });

    test('writes every record as UTF-8 text ending in a line break', () async {
      final logger = CfLogger(capacity: 10)
        ..info('test', 'first')
        ..warn('test', 'second', fields: {'name': 'ü'});
      final broker = FakeStorageBroker()..saveAnswer = 'logs.txt';
      final saved = await saveLogs(
        broker,
        logger: logger,
        now: DateTime(2026, 11, 12, 9, 30),
      );
      expect(saved.valueOrNull, 'logs.txt');
      final file = broker.saved.single;
      expect(file.suggestedName, 'codeforge-logs-20261112-0930.txt');
      expect(file.mimeType, 'text/plain');
      final text = utf8.decode(file.bytes);
      expect(text, contains('[info] test/first'));
      expect(text, contains('[warn] test/second name=ü'));
      expect(text.indexOf('test/first'), lessThan(text.indexOf('test/second')));
      expect(text, endsWith('\n'));
    });

    test('backing out of the picker saves nothing', () async {
      final broker = FakeStorageBroker();
      final saved = await saveLogs(broker, logger: CfLogger(capacity: 10));
      expect(saved, isA<Ok<String?>>());
      expect(saved.valueOrNull, isNull);
      expect(broker.calls, ['saveDocument']);
      expect(broker.saved, isEmpty);
    });

    test('a failure says what happened and what to do', () async {
      final broker = FakeStorageBroker()
        ..saveAnswer = 'logs.txt'
        ..failNextSave = const FileFailure(
          'timeout',
          problem: FileProblem.timeout,
        );
      final saved = await saveLogs(broker, logger: CfLogger(capacity: 10));
      expect(saved.failureOrNull, isA<FileFailure>());
      expect(
        saveLogsFailureMessage(saved.failureOrNull!),
        'Logs not saved: the storage did not answer in time. Try again.',
      );
      expect(
        saveLogsFailureMessage(
          const FileFailure('none', problem: FileProblem.unsupported),
        ),
        'Logs not saved: this device has no picker to save files with.',
      );
      expect(
        saveLogsFailureMessage(
          const FileFailure('io', problem: FileProblem.io),
        ),
        'Logs not saved: the storage failed. Try again, or pick another '
        'place.',
      );
    });
  });

  group('the Recent logs screen', () {
    testWidgets('Save writes the logs and names the file', (tester) async {
      appLogger.info('test', 'save_logs_marker');
      final broker = FakeStorageBroker()
        ..saveAnswer = 'codeforge-logs-mine.txt';
      await _openLogs(tester, broker);
      await _tapSave(tester);

      final file = broker.saved.single;
      expect(
        file.suggestedName,
        matches(RegExp(r'^codeforge-logs-\d{8}-\d{4}\.txt$')),
      );
      expect(utf8.decode(file.bytes), contains('test/save_logs_marker'));
      expect(find.text('Logs saved to codeforge-logs-mine.txt'), findsOneWidget);
    });

    testWidgets('backing out says nothing', (tester) async {
      final broker = FakeStorageBroker();
      await _openLogs(tester, broker);
      await _tapSave(tester);

      expect(broker.calls, contains('saveDocument'));
      expect(broker.saved, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a failure is reported', (tester) async {
      final broker = FakeStorageBroker()
        ..saveAnswer = 'logs.txt'
        ..failNextSave = const FileFailure('io', problem: FileProblem.io);
      await _openLogs(tester, broker);
      await _tapSave(tester);

      expect(
        find.text(
          'Logs not saved: the storage failed. Try again, or pick another '
          'place.',
        ),
        findsOneWidget,
      );
    });
  });
}
