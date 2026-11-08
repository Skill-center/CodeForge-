/// A hardware keyboard tests attach and detach (Phase 2 W6), standing in
/// for MainActivity's report of Android's configuration.
library;

import 'dart:async';

import 'package:codeforge/services/platform/hardware_keyboard.dart';

final class FakeHardwareKeyboard implements HardwareKeyboardSource {
  FakeHardwareKeyboard({bool attached = false}) : _attached = attached;

  bool _attached;
  final List<StreamController<bool>> _watchers = [];

  bool get attached => _attached;

  /// Attaches or detaches the keyboard; every watcher hears of it.
  set attached(bool value) {
    _attached = value;
    for (final watcher in _watchers) {
      watcher.add(value);
    }
  }

  @override
  Stream<bool> watch() {
    late final StreamController<bool> watcher;
    watcher = StreamController<bool>(
      onListen: () => watcher.add(_attached),
      onCancel: () {
        _watchers.remove(watcher);
        return watcher.close();
      },
    );
    _watchers.add(watcher);
    return watcher.stream;
  }
}
