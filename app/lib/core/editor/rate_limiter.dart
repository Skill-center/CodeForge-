/// Rate limit for messages from the editor page (docs/SECURITY.md §3).
library;

import 'dart:math' as math;

/// A token bucket: [capacity] messages in a burst, refilled at
/// [refillPerSecond]. The page normally sends a handful of messages per
/// second (edits are batched every 150 ms), so the limit only bites on a
/// runaway or hostile page, and the host drops what exceeds it.
final class MessageRateLimiter {
  MessageRateLimiter({
    this.capacity = 240,
    this.refillPerSecond = 120,
    int Function()? nowMicros,
  }) : _nowMicros = nowMicros ?? _monotonicMicros(),
       _tokens = capacity.toDouble() {
    _lastMicros = _nowMicros();
  }

  final int capacity;
  final double refillPerSecond;
  final int Function() _nowMicros;
  double _tokens;
  late int _lastMicros;

  /// Takes one token; false means the message must be dropped.
  bool tryAcquire() {
    final now = _nowMicros();
    final elapsedSeconds = (now - _lastMicros) / Duration.microsecondsPerSecond;
    _lastMicros = now;
    _tokens = math.min(
      capacity.toDouble(),
      _tokens + elapsedSeconds * refillPerSecond,
    );
    if (_tokens < 1) {
      return false;
    }
    _tokens -= 1;
    return true;
  }

  static int Function() _monotonicMicros() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds;
  }
}
