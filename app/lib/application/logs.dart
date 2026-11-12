/// What About → Recent logs → Copy puts on the clipboard (Phase 3 W1), and
/// what Save writes to a file (W4).
library;

import 'dart:convert';

import '../core/errors/failure.dart';
import '../core/logging/logger.dart';
import '../services/files/storage_broker.dart';
import '../services/logging/file_log_sink.dart';

/// How much of the log files Copy takes: the newest 256 KiB.
const int copiedLogBytes = 256 * 1024;

/// How much Save takes: all of it. The log file and the one before it hold
/// at most about 2 MiB (FileLogSink).
const int savedLogBytes = 4 * 1024 * 1024;

/// The newest [maxBytes] of the log files, this session's and earlier
/// ones', oldest first; or, while the log file is not running, the records
/// [logger] holds in memory (this session's latest).
Future<String> recentLogText({
  CfLogger? logger,
  int maxBytes = copiedLogBytes,
}) async {
  final file = activeFileLog;
  if (file != null && file.active) {
    final text = await file.readRecent(maxBytes: maxBytes);
    if (text.isNotEmpty) {
      return text;
    }
  }
  return [
    for (final record in (logger ?? appLogger).records) record.render(),
  ].join('\n');
}

/// The name Save suggests, in local time: `codeforge-logs-20261112-0531.txt`.
String savedLogName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'codeforge-logs-${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}.txt';
}

/// About → Recent logs → Save (Phase 3 W4): writes the log files' text,
/// redacted as it was logged, to a new file the user makes in Android's
/// create-document picker. The app keeps no access to that file. Answers
/// the file's name ('' when its storage does not say), or null when the
/// user backs out.
Future<Result<String?>> saveLogs(
  StorageBroker broker, {
  DateTime? now,
  CfLogger? logger,
}) async {
  final log = logger ?? appLogger;
  var text = await recentLogText(logger: log, maxBytes: savedLogBytes);
  if (text.isNotEmpty && !text.endsWith('\n')) {
    text = '$text\n';
  }
  final bytes = utf8.encode(text);
  final saved = await broker.saveDocument(
    suggestedName: savedLogName(now ?? DateTime.now()),
    mimeType: 'text/plain',
    bytes: bytes,
  );
  switch (saved) {
    case Ok(value: null):
      log.info('logs', 'save_cancelled');
    case Ok():
      log.info('logs', 'saved', fields: {'bytes': bytes.length});
    case Err(:final failure):
      log.warn(
        'logs',
        'save_failed',
        fields: {
          'problem': failure is FileFailure ? failure.problem.name : 'other',
        },
      );
  }
  return saved;
}

/// What a failed Save says: what happened and what to do
/// (docs/UI_DESIGN_SYSTEM.md §7).
String saveLogsFailureMessage(Failure failure) {
  final problem = failure is FileFailure ? failure.problem : FileProblem.io;
  return switch (problem) {
    FileProblem.unsupported =>
      'Logs not saved: this device has no picker to save files with.',
    FileProblem.timeout =>
      'Logs not saved: the storage did not answer in time. Try again.',
    _ =>
      'Logs not saved: the storage failed. Try again, or pick another place.',
  };
}
