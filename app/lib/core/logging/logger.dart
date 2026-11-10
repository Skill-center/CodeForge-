/// Structured logging with a bounded in-memory ring buffer and redaction.
///
/// Records go to the ring buffer (About → Recent logs) and to the sinks:
/// the debug console in debug builds (bootstrap), and since Phase 3 W1 a
/// file in the folder Android never backs up
/// (services/logging/file_log_sink.dart). Redaction happens here, never at
/// call sites (docs/SECURITY.md §4), so every sink gets redacted records.
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

/// A `content://` URI: its authority, then the rest up to white space.
final RegExp _contentUriPattern = RegExp(r'content://([^/\s]*)[^\s]*');

/// Returns a copy of [fields] with secret-looking values redacted, and
/// `content://` URIs in text cut to their authority: a document URI names
/// the user's folders and files (Phase 3's storage broker).
Map<String, Object?> redactFields(Map<String, Object?> fields) {
  return fields.map((key, value) {
    if (_secretKeyPattern.hasMatch(key)) {
      return MapEntry(key, '[redacted]');
    }
    if (value is String && value.contains('content://')) {
      return MapEntry(
        key,
        value.replaceAllMapped(
          _contentUriPattern,
          (match) => 'content://${match[1]}/…',
        ),
      );
    }
    return MapEntry(key, value);
  });
}

/// App-wide structured logger. Pure Dart; sinks are added at bootstrap.
final class CfLogger {
  CfLogger({this.capacity = 500, LogSink? sink}) : _sink = sink;

  final int capacity;
  LogSink? _sink;
  final List<LogSink> _sinks = [];
  final Queue<LogRecord> _buffer = Queue<LogRecord>();

  /// The console sink (bootstrap): replaced, never added to.
  set sink(LogSink? value) => _sink = value;

  /// Adds a sink that receives every record from now on, after the
  /// console sink.
  void addSink(LogSink sink) => _sinks.add(sink);

  /// Removes a sink [addSink] added; true if it was there.
  bool removeSink(LogSink sink) => _sinks.remove(sink);

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
    for (final sink in List.of(_sinks)) {
      sink(record);
    }
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
