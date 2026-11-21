/// Host → page messages through a MessagePort (Phase 5 W6,
/// docs/TERMINAL_ARCHITECTURE.md §2.2), the app's side.
///
/// As a page finishes loading, the native side (app/android's
/// webview/PagePorts.kt) makes a message channel with Android's
/// WebView.createWebMessageChannel, keeps one end and posts the page the
/// other (WebView.postWebMessage, to the page's origin only). The page
/// (editor/src/terminal/hostport.ts) takes it and says so in its ready
/// announcement; from then on the surface (webview_editor_surface.dart)
/// sends through the port rather than as one script per message, which the
/// page had to parse and compile and whose garbage stayed in its heap after
/// a flood.
library;

import 'package:flutter/services.dart';

/// The channel to the native side: `open`, `post` and `close`, each for one
/// WebView by its webview_flutter identifier.
const MethodChannel pagePortChannel = MethodChannel('dev.codeforge/page_port');

final class PagePorts {
  const PagePorts([this._channel = pagePortChannel]);

  final MethodChannel _channel;

  /// Posts the page loaded in WebView [webView] the end of a new channel,
  /// for [origin] only; a port opened for it before is closed. Answers
  /// whether it could: false without the native side, or without a WebView
  /// of that identifier. Never throws.
  Future<bool> open(int webView, {required String origin}) async {
    try {
      final opened = await _channel.invokeMethod<bool>('open', {
        'webView': webView,
        'origin': origin,
      });
      return opened ?? false;
    } on Object {
      return false;
    }
  }

  /// Sends [message] through [webView]'s port. Throws when it has none.
  Future<void> post(int webView, String message) {
    return _channel.invokeMethod<void>('post', {
      'webView': webView,
      'message': message,
    });
  }

  /// Closes [webView]'s port, if it has one. Never throws.
  Future<void> close(int webView) async {
    try {
      await _channel.invokeMethod<void>('close', {'webView': webView});
    } on Object {
      // Nothing left to close.
    }
  }
}
