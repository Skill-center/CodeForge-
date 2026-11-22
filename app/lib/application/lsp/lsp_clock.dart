/// Time for the language clients (Phase 6 W4): the real clocks, or a test's.
/// The clients never make a timer or read a clock but through this, so their
/// timeouts, restart backoff and idle stop can be tested without waiting.
library;

import 'dart:async';
import 'dart:developer' show Timeline;

abstract interface class LspClock {
  /// Milliseconds on a clock that never goes back: the restart window.
  int get nowMs;

  /// Microseconds on the monotonic clock the host stamps its messages with
  /// (Kotlin's System.nanoTime): a request's stages.
  int get monotonicUs;

  /// Runs [callback] once, after [delay].
  Timer timer(Duration delay, void Function() callback);
}

/// The real clocks.
final class SystemLspClock implements LspClock {
  const SystemLspClock();

  static final Stopwatch _elapsed = Stopwatch()..start();

  @override
  int get nowMs => _elapsed.elapsedMilliseconds;

  /// The VM's trace clock: CLOCK_MONOTONIC on Android, as System.nanoTime.
  @override
  int get monotonicUs => Timeline.now;

  @override
  Timer timer(Duration delay, void Function() callback) =>
      Timer(delay, callback);
}
