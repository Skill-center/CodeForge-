/// Structured logging with a bounded in-memory ring buffer and redaction.
///
/// Phase 1: memory buffer + injectable sink (debug console in bootstrap).
/// The on-disk sink arrives with the storage layer in Phase 2; the interface
/// does not change. Redaction happens here, never at call sites
/// (docs/SECURITY.md §4).
library;

import 'dart:collection';

enum LogLevel { debug, info, warn, error }

/// One structured log entry.
final class LogRecord {
  LogRecord({
    required this.time,
    required this.level,
    required this.tag,
    required this.event,
    Map<String, Object?> fields = const {},
  }) : fields = Map.unmodifiable(fields);

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String event;
  final Map<String, Object?> fields;

  String render() {
    final renderedFields = fields.entries
        .map((e) => '${e.key}=${e.value}')
        .join(' ');
    final suffix = renderedFields.isEmpty ? '' : ' $renderedFields';
    return '${time.toIso8601String()} [${level.name}] $tag/$event$suffix';
  }
}

/// Receives rendered records (console, file, …).
typedef LogSink = void Function(LogRecord record);

/// Field names whose values must never be logged verbatim.
final RegExp _secretKeyPattern = RegExp(
  r'token|secret|password|passwd|credential|authorization|api_?key|private_?key|ssh_?key',
  caseSensitive: false,
);

/// Returns a copy of [fields] with secret-looking values redacted.
Map<String, Object?> redactFields(Map<String, Object?> fields) {
  return fields.map((key, value) {
    if (_secretKeyPattern.hasMatch(key)) {
      return MapEntry(key, '[redacted]');
    }
    return MapEntry(key, value);
  });
}

/// App-wide structured logger. Pure Dart; the sink is injected at bootstrap.
final class CfLogger {
  CfLogger({this.capacity = 500, LogSink? sink}) : _sink = sink;

  final int capacity;
  LogSink? _sink;
  final Queue<LogRecord> _buffer = Queue<LogRecord>();

  set sink(LogSink? value) => _sink = value;

  /// Unmodifiable view of the ring buffer, oldest first.
  List<LogRecord> get records => List.unmodifiable(_buffer);

  void log(
    LogLevel level,
    String tag,
    String event, {
    Map<String, Object?> fields = const {},
  }) {
    final record = LogRecord(
      time: DateTime.now(),
      level: level,
      tag: tag,
      event: event,
      fields: redactFields(fields),
    );
    _buffer.addLast(record);
    while (_buffer.length > capacity) {
      _buffer.removeFirst();
    }
    _sink?.call(record);
  }

  void debug(
    String tag,
    String event, {
    Map<String, Object?> fields = const {},
  }) => log(LogLevel.debug, tag, event, fields: fields);

  void info(
    String tag,
    String event, {
    Map<String, Object?> fields = const {},
  }) => log(LogLevel.info, tag, event, fields: fields);

  void warn(
    String tag,
    String event, {
    Map<String, Object?> fields = const {},
  }) => log(LogLevel.warn, tag, event, fields: fields);

  void error(
    String tag,
    String event, {
    Map<String, Object?> fields = const {},
  }) => log(LogLevel.error, tag, event, fields: fields);
}

/// The process-wide logger instance.
final CfLogger appLogger = CfLogger();
