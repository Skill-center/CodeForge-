/// The keyboards the workbench lays itself out for (Phase 2 W6): whether the
/// soft keyboard is up, and whether a hardware keyboard is attached.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/platform/hardware_keyboard.dart';

/// Whether the soft keyboard is up: the window's bottom inset. The
/// Scaffold takes that inset out of its body's MediaQuery, so widgets in
/// the body cannot read it themselves.
final softKeyboardVisibleProvider =
    NotifierProvider<SoftKeyboardController, bool>(SoftKeyboardController.new);

final class SoftKeyboardController extends Notifier<bool>
    with WidgetsBindingObserver {
  @override
  bool build() {
    final binding = WidgetsBinding.instance..addObserver(this);
    ref.onDispose(() => binding.removeObserver(this));
    return _keyboardUp();
  }

  bool _keyboardUp() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    return views.isNotEmpty && views.first.viewInsets.bottom > 0;
  }

  @override
  void didChangeMetrics() {
    final up = _keyboardUp();
    if (up != state) {
      state = up;
    }
  }
}

/// Where the hardware keyboard's presence comes from; tests replace it.
final hardwareKeyboardSourceProvider = Provider<HardwareKeyboardSource>(
  (ref) => PlatformHardwareKeyboard(),
);

/// Whether a hardware keyboard is attached. With one, the symbol toolbar
/// steps aside: its keys are on the keyboard.
final hardwareKeyboardProvider =
    NotifierProvider<HardwareKeyboardController, bool>(
      HardwareKeyboardController.new,
    );

final class HardwareKeyboardController extends Notifier<bool> {
  @override
  bool build() {
    final subscription = ref
        .watch(hardwareKeyboardSourceProvider)
        .watch()
        .listen((attached) => state = attached);
    ref.onDispose(() => unawaited(subscription.cancel()));
    return false;
  }
}
