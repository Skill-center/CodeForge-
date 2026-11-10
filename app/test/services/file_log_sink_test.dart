/// The log file (Phase 3 W1, gate G6): it rotates at its limit, writes
/// errors at once and the rest in batches, cuts long records, keeps one
/// line per record, replays what was logged before it opened, and gets
/// redacted records only. Plain tests: real files in real time.
library;

import 'dart:async';
import 'dart:io';

import 'package:codeforge/application/logs.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/services/logging/file_log_sink.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _temp;

String get _logs => '${_temp.path}/no_backup/logs';

LogRecord _record(
  String event, {
  LogLevel level = LogLevel.info,
  Map<String, Object?> fields = const {},
}) => LogRecord(
  time: DateTime.utc(2026, 11, 10, 12),
  level: level,
  tag: 'test',
  event: event,
  fields: fields,
);

String _read(File file) => file.existsSync() ? file.readAsStringSync() : '';

void main() {
  setUp(() async {
    _temp = await Directory.systemTemp.createTemp('codeforge_logs_');
  });

  tearDown(() async {
    stopFileLog(appLogger);
    await _temp.delete(recursive: true);
  });

  test('a session starts with a marker line', () {
    final sink = FileLogSink(_logs)..open();
    addTearDown(sink.close);
    expect(sink.active, isTrue);
    expect(sink.marker, startsWith('=== session '));
    expect(sink.marker, contains('pid $pid'));
    expect(_read(sink.current), '${sink.marker}\n');
  });

  test('errors are on disk when add returns; the rest waits', () {
    final sink = FileLogSink(_logs, flushEvery: const Duration(hours: 1))
      ..open();
    addTearDown(sink.close);
    sink.add(_record('quiet'));
    expect(_read(sink.current), isNot(contains('quiet')));
    sink.add(_record('broke', level: LogLevel.error));
    final text = _read(sink.current);
    expect(text, contains('test/quiet'));
    expect(text, contains('[error] test/broke'));
    expect(text.indexOf('quiet'), lessThan(text.indexOf('broke')));
  });

  test('a batch is written after flushEvery', () async {
    final sink = FileLogSink(
      _logs,
      flushEvery: const Duration(milliseconds: 50),
    )..open();
    addTearDown(sink.close);
    sink.add(_record('later'));
    expect(_read(sink.current), isNot(contains('later')));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(_read(sink.current), contains('test/later'));
  });

  test('16 KiB waiting are written at once', () {
    final sink = FileLogSink(_logs, flushEvery: const Duration(hours: 1))
      ..open();
    addTearDown(sink.close);
    final filler = 'x' * 1000;
    for (var i = 0; i < 17; i++) {
      sink.add(_record('fill$i', fields: {'text': filler}));
    }
    // No flush call and no timer: the batch went once 16 KiB waited.
    final text = _read(sink.current);
    expect(text, contains('test/fill0 '));
    expect(text.length, greaterThanOrEqualTo(16 * 1024));
  });

  test('the file rotates at its limit; two files at most', () {
    final sink = FileLogSink(
      _logs,
      maxFileBytes: 4096,
      flushEvery: const Duration(hours: 1),
    )..open();
    addTearDown(sink.close);
    for (var i = 0; i < 40; i++) {
      sink
        ..add(_record('r$i', fields: {'text': 'y' * 300}))
        ..flush();
    }
    expect(sink.current.lengthSync(), lessThanOrEqualTo(4096));
    expect(sink.previous.lengthSync(), lessThanOrEqualTo(4096));
    expect(_read(sink.current), contains('test/r39 '));
    expect(_read(sink.previous), isNot(contains('test/r39 ')));
    expect(
      Directory(_logs).listSync().map((e) => e.path.split('/').last).toSet(),
      {FileLogSink.currentName, FileLogSink.previousName},
    );
  });

  test('long records are cut; line breaks stay inside the line', () {
    final sink = FileLogSink(
      _logs,
      maxRecordChars: 200,
      flushEvery: const Duration(hours: 1),
    )..open();
    addTearDown(sink.close);
    sink
      ..add(_record('long', fields: {'text': 'z' * 1000}))
      ..add(_record('lines', fields: {'error': 'first\nsecond\r\nthird'}))
      ..flush();
    final lines = _read(sink.current).trimRight().split('\n');
    expect(lines, hasLength(3));
    expect(lines[1], contains('more chars cut]'));
    expect(lines[1].length, lessThan(240));
    expect(lines[2], endsWith(r'error=first\nsecond\nthird'));
  });

  test('a later session appends after the earlier one', () {
    final first = FileLogSink(_logs)..open();
    first
      ..add(_record('before', level: LogLevel.error))
      ..close();
    final second = FileLogSink(_logs)..open();
    addTearDown(second.close);
    final text = _read(second.current);
    expect(text.indexOf('test/before'), greaterThan(0));
    // The two markers can match to the millisecond: find the last one.
    expect(
      text.indexOf('test/before'),
      lessThan(text.lastIndexOf(second.marker!)),
    );
  });

  test('a folder that cannot be written leaves the sink off', () {
    File('${_temp.path}/blocked').writeAsStringSync('a file, not a folder');
    final sink = FileLogSink('${_temp.path}/blocked/logs');
    expect(sink.open(), isFalse);
    expect(sink.active, isFalse);
    sink.add(_record('nowhere', level: LogLevel.error)); // no throw
  });

  test('readRecent: the newest bytes of both files, from a line', () async {
    final sink = FileLogSink(
      _logs,
      maxFileBytes: 2048,
      flushEvery: const Duration(hours: 1),
    )..open();
    addTearDown(sink.close);
    for (var i = 0; i < 30; i++) {
      sink.add(_record('e$i', fields: {'text': 'w' * 100}));
      sink.flush();
    }
    final all = await sink.readRecent(maxBytes: 1 << 20);
    expect(all, '${_read(sink.previous)}${_read(sink.current)}');

    final tail = await sink.readRecent(maxBytes: 3000);
    expect(tail.length, lessThanOrEqualTo(3000));
    expect(all, endsWith(tail));
    expect(tail, contains('test/e29 '));
    // Starts at a line: a record or the session marker, never a fragment.
    expect(tail, matches(RegExp(r'^(\d{4}-|=== session)')));
  });

  test('startFileLog replays earlier records, then takes new ones', () async {
    final logger = CfLogger()
      ..info('boot', 'early', fields: {'token': 'ghp_secret'});
    final sink = await startFileLog(
      logger,
      folder: () async => '${_temp.path}/no_backup',
      watchLifecycle: false,
    );
    expect(sink, isNotNull);
    expect(sink!.current.path, '$_logs/codeforge.log');
    expect(identical(activeFileLog, sink), isTrue);
    // Once per process: a second call returns the same file.
    expect(identical(await startFileLog(logger), sink), isTrue);

    logger.error('boot', 'late');
    final text = _read(sink.current);
    expect(text, contains('boot/early token=[redacted]'));
    expect(text, isNot(contains('ghp_secret')));
    expect(text.indexOf('boot/early'), lessThan(text.indexOf('boot/late')));
    stopFileLog(logger);

    logger.error('boot', 'after_stop');
    expect(_read(sink.current), isNot(contains('after_stop')));
  });

  test('startFileLog without a folder runs on without a file', () async {
    final sink = await startFileLog(
      CfLogger(),
      folder: () async => throw StateError('no folder'),
      watchLifecycle: false,
    );
    expect(sink, isNull);
    expect(activeFileLog, isNull);
  });

  test('Copy takes the file, or the memory without one', () async {
    final logger = CfLogger()..info('copy', 'in_memory');
    expect(await recentLogText(logger: logger), contains('copy/in_memory'));

    await startFileLog(
      logger,
      folder: () async => '${_temp.path}/no_backup',
      watchLifecycle: false,
    );
    logger.warn('copy', 'on_file');
    final copied = await recentLogText(logger: logger);
    expect(copied, startsWith('=== session '));
    expect(copied, contains('copy/in_memory'));
    expect(copied, contains('copy/on_file'));
  });
}
