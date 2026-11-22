/// A clock the language clients' tests move by hand (Phase 6 W4): timers
/// fire only when [FakeLspClock.advance] passes their time, in order, so
/// timeouts, the restart backoff and the idle stop run without waiting.
library;

import 'dart:async';

import 'package:codeforge/application/lsp/lsp_clock.dart';

final class FakeLspClock implements LspClock {
  /// Starts a second in, so no stage measures from 0.
  int _nowUs = 1000000;
  final List<_FakeTimer> _timers = [];

  @override
  int get nowMs => _nowUs ~/ 1000;

  @override
  int get monotonicUs => _nowUs;

  @override
  Timer timer(Duration delay, void Function() callback) {
    final timer = _FakeTimer(_nowUs + delay.inMicroseconds, callback);
    _timers.add(timer);
    return timer;
  }

  /// Timers not yet fired or cancelled.
  int get pending => _timers.where((timer) => timer.isActive).length;

  /// Moves time on by [by], firing each timer that falls due, in order of
  /// their times.
  void advance(Duration by) {
    final end = _nowUs + by.inMicroseconds;
    while (true) {
      _timers.removeWhere((timer) => !timer.isActive);
      final due = _timers.where((timer) => timer.dueUs <= end).toList()
        ..sort((a, b) => a.dueUs.compareTo(b.dueUs));
      if (due.isEmpty) {
        break;
      }
      final next = due.first;
      if (next.dueUs > _nowUs) {
        _nowUs = next.dueUs;
      }
      next.fire();
    }
    _nowUs = end;
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this.dueUs, this._callback);

  final int dueUs;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _callback();
  }
}
