/// What About → Recent logs → Copy puts on the clipboard (Phase 3 W1).
library;

import '../core/logging/logger.dart';
import '../services/logging/file_log_sink.dart';

/// How much of the log files Copy takes: the newest 256 KiB.
const int copiedLogBytes = 256 * 1024;

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
