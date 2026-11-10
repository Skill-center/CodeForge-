/// The log file (Phase 3 W1): what the app logs, kept across restarts and
/// crashes in the folder Android never backs up, for About → Recent logs →
/// Copy.
///
/// - **Files:** `<no-backup files>/logs/codeforge.log`, and the one before
///   it, `codeforge.1.log`: when the current file would pass
///   [FileLogSink.maxFileBytes] it becomes the previous one, so the two
///   hold at most about 2 MiB.
/// - **Lines:** each session starts with a marker line; each record is one
///   line (line breaks written as `\n`), cut at
///   [FileLogSink.maxRecordChars]. Records are redacted before they get
///   here (CfLogger).
/// - **Writes:** batched. An error goes to disk at once, before `add`
///   returns, in case it is the last thing the process does; the rest when
///   16 KiB wait, after 5 s, and when the app is hidden, paused or
///   detached. A plain write survives the process: only a power cut can
///   lose a batch.
/// - **Failures:** a write that fails turns the file off for the session.
///   The sink never logs: that would only come back to it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../core/logging/logger.dart';
import '../../core/version.dart';
import '../platform/app_directories.dart';

final class FileLogSink {
  FileLogSink(
    this.directory, {
    this.maxFileBytes = 1024 * 1024,
    this.flushAboveChars = 16 * 1024,
    this.flushEvery = const Duration(seconds: 5),
    this.maxRecordChars = 8 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Where the files live: `<no-backup files>/logs`.
  final String directory;

  /// The current file's limit; past it, it becomes the previous one.
  final int maxFileBytes;

  /// Waiting text that is written at once.
  final int flushAboveChars;

  /// How long a record waits at most, unless the app is hidden first.
  final Duration flushEvery;

  /// A longer record is cut, and says by how much.
  final int maxRecordChars;

  final DateTime Function() _clock;

  static const String currentName = 'codeforge.log';
  static const String previousName = 'codeforge.1.log';

  File get current => File('$directory/$currentName');
  File get previous => File('$directory/$previousName');

  final StringBuffer _pending = StringBuffer();
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  int _size = 0;
  bool _open = false;
  bool _failed = false;

  /// This session's marker line, once [open] wrote it.
  String? marker;

  /// Whether records still reach the file.
  bool get active => _open && !_failed;

  /// The line that starts a session.
  static String sessionMarker(DateTime time) =>
      '=== session ${time.toUtc().toIso8601String()} · CodeForge '
      '$appVersion · pid $pid ===';

  /// Creates the folder and writes the session marker. False when the
  /// folder or the file cannot be written: the sink stays off.
  bool open() {
    if (_open) {
      return active;
    }
    try {
      Directory(directory).createSync(recursive: true);
      _size = current.existsSync() ? current.lengthSync() : 0;
    } on Object {
      _failed = true;
      return false;
    }
    _open = true;
    final line = sessionMarker(_clock());
    marker = line;
    _pending.writeln(line);
    flush();
    return active;
  }

  /// Takes one record: the logger calls this for every record it keeps.
  void add(LogRecord record) {
    if (!active) {
      return;
    }
    _append(record);
    if (record.level == LogLevel.error) {
      flush(durable: true);
    } else if (_pending.length >= flushAboveChars) {
      flush();
    } else {
      _timer ??= Timer(flushEvery, flush);
    }
  }

  /// Takes records logged before the file opened, then writes them.
  void replay(Iterable<LogRecord> records) {
    if (!active) {
      return;
    }
    records.forEach(_append);
    flush(durable: true);
  }

  void _append(LogRecord record) {
    var line = record.render().replaceAll('\r', '').replaceAll('\n', r'\n');
    if (line.length > maxRecordChars) {
      final cut = line.length - maxRecordChars;
      line = '${line.substring(0, maxRecordChars)} …[$cut more chars cut]';
    }
    _pending.writeln(line);
  }

  /// Writes what is waiting. [durable] also asks the system to put it on
  /// the storage itself, not only in its cache.
  void flush({bool durable = false}) {
    _timer?.cancel();
    _timer = null;
    if (!active || _pending.isEmpty) {
      return;
    }
    final bytes = utf8.encode(_pending.toString());
    _pending.clear();
    try {
      if (_size > 0 && _size + bytes.length > maxFileBytes) {
        current.renameSync(previous.path);
        _size = 0;
      }
      current.writeAsBytesSync(bytes, mode: FileMode.append, flush: durable);
      _size += bytes.length;
    } on Object {
      _failed = true;
    }
  }

  /// Writes what is waiting whenever the app is hidden, paused or
  /// detached: Android may end a hidden app's process without a word.
  void watchLifecycle() {
    _lifecycle ??= AppLifecycleListener(
      onHide: flush,
      onPause: flush,
      onDetach: flush,
    );
  }

  /// Writes what is waiting and stops taking records.
  void close() {
    flush();
    _lifecycle?.dispose();
    _lifecycle = null;
    _open = false;
  }

  /// The newest [maxBytes] of both files, oldest first, from the start of
  /// a line; empty if there is none.
  Future<String> readRecent({int maxBytes = 256 * 1024}) async {
    flush();
    final newer = await _tail(current, maxBytes);
    final older = newer.length < maxBytes
        ? await _tail(previous, maxBytes - newer.length)
        : const <int>[];
    var bytes = [...older, ...newer];
    final whole = bytes.length == _length(current) + _length(previous);
    if (!whole) {
      // Cut inside a line, maybe inside a character: start at the next.
      final next = bytes.indexOf(0x0A);
      bytes = next < 0 ? <int>[] : bytes.sublist(next + 1);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static int _length(File file) {
    try {
      return file.lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  static Future<List<int>> _tail(File file, int count) async {
    if (count <= 0) {
      return const [];
    }
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final length = await handle.length();
      final start = math.max(0, length - count);
      await handle.setPosition(start);
      return await handle.read(length - start);
    } on FileSystemException {
      return const [];
    } finally {
      await handle?.close();
    }
  }
}

FileLogSink? _active;

/// The log file, once [startFileLog] opened it.
FileLogSink? get activeFileLog => _active;

/// Opens the log file and sends [logger]'s records to it: first the ones it
/// already holds (bootstrap starts this after the first frame), then every
/// new one. Once per process: later calls return the same file. Null when
/// the folder cannot be found or written; the app then runs on with the
/// in-memory records alone.
Future<FileLogSink?> startFileLog(
  CfLogger logger, {
  Future<String> Function() folder = noBackupFilesPath,
  bool watchLifecycle = true,
}) async {
  if (_active case final active?) {
    return active;
  }
  final String base;
  try {
    base = await folder();
  } on Object {
    return null;
  }
  // Another call may have finished while this one waited.
  if (_active case final active?) {
    return active;
  }
  final sink = FileLogSink('$base/logs');
  if (!sink.open()) {
    return null;
  }
  // Nothing can log between the replay and addSink: no await between them.
  sink.replay(logger.records);
  logger.addSink(sink.add);
  if (watchLifecycle) {
    sink.watchLifecycle();
  }
  return _active = sink;
}

/// Stops the log file [startFileLog] opened, for tests.
@visibleForTesting
void stopFileLog(CfLogger logger) {
  final sink = _active;
  if (sink == null) {
    return;
  }
  logger.removeSink(sink.add);
  sink.close();
  _active = null;
}
