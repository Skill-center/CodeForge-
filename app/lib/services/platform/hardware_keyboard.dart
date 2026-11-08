/// Whether a hardware keyboard is attached (Phase 2 W6). Android says so in
/// its configuration, which MainActivity reports over `dev.codeforge/
/// keyboard`: `attached` answers now, and `changed` arrives whenever a
/// keyboard comes or goes. Without that channel (tests, other platforms)
/// there is no keyboard.
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// Tells whether a hardware keyboard is attached, and when that changes.
abstract interface class HardwareKeyboardSource {
  /// The current answer first, then every change.
  Stream<bool> watch();
}

final class PlatformHardwareKeyboard implements HardwareKeyboardSource {
  PlatformHardwareKeyboard([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('dev.codeforge/keyboard');

  final MethodChannel _channel;

  @override
  Stream<bool> watch() {
    final controller = StreamController<bool>();
    controller
      ..onListen = () {
        _channel.setMethodCallHandler((call) async {
          final attached = call.arguments;
          if (call.method == 'changed' && attached is bool) {
            controller.add(attached);
          }
        });
        unawaited(_askNow(controller));
      }
      ..onCancel = () {
        _channel.setMethodCallHandler(null);
        return controller.close();
      };
    return controller.stream;
  }

  Future<void> _askNow(StreamController<bool> controller) async {
    var attached = false;
    try {
      attached = await _channel.invokeMethod<bool>('attached') ?? false;
    } on MissingPluginException {
      attached = false;
    } on PlatformException {
      attached = false;
    }
    if (!controller.isClosed) {
      controller.add(attached);
    }
  }
}
