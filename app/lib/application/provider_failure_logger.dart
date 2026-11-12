/// Provider failures in the log (Phase 3 W6, an owner item of 2026-11-11).
///
/// A provider that throws while it builds, or whose future or stream ends
/// in an error, is logged under the tag `provider` at the error level: its
/// name (or its type, and its argument for a family), the error, and the
/// first frame of the app's own code in the stack. It goes through the
/// logger, so the logger's redaction applies (a `content://` URI keeps only
/// its authority) and every sink gets it: About → Recent logs, the log
/// file, and Settings → Developer → Log viewer.
///
/// Riverpod tries a provider that failed with an `Exception` again, up to
/// ten times, waiting longer each time; each failure is logged.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/logger.dart';

final class ProviderFailureLogger extends ProviderObserver {
  /// Logs to [logger], or to the app's logger when it is null.
  const ProviderFailureLogger({this.logger});

  final CfLogger? logger;

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    (logger ?? appLogger).error(
      'provider',
      'failed',
      fields: {
        'provider': '${context.provider}',
        'error': '$error',
        'at': appFrameOf(stackTrace),
      },
    );
  }
}

/// The first frame of [stackTrace] in the app's own code (`package:codeforge`),
/// cut to the file, line and column; null when the stack has none.
String? appFrameOf(StackTrace stackTrace) {
  final match = _appFrame.firstMatch('$stackTrace');
  return match?.group(0);
}

final RegExp _appFrame = RegExp(r'package:codeforge/[^\s)]+');
