/// The WebView that hosts one engine benchmark page (Phase 2 W3): Settings →
/// Developer → Editor benchmark, and the phase gate's integration test.
///
/// Same hardening as the editor's WebViewEditorSurface: no navigation, no
/// file or content access, no dialogs, remote debugging in debug builds only
/// (the gate's DevTools driver attaches to the debug APK).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// The pages' origin: the editor's virtual host, under its own path.
const String benchPageBaseUrl =
    'https://appassets.androidplatform.net/editor_bench/';

/// The JavaScript channel the page posts its messages to.
const String benchChannelName = 'CodeForgeBench';

/// One benchmark page on screen.
abstract interface class BenchSurface {
  /// Messages the page posts (JSON objects; anything else is dropped), plus
  /// `{type: console}` entries for the page's console warnings and errors.
  Stream<Map<String, Object?>> get messages;

  Future<void> load(String html);

  /// Runs a script in the page. Results come back as [messages].
  Future<void> execute(String script);

  Widget buildView(BuildContext context);

  Future<void> dispose();
}

final class WebViewBenchSurface implements BenchSurface {
  WebViewBenchSurface() : _controller = WebViewController();

  final WebViewController _controller;
  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  Future<void>? _setup;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> load(String html) async {
    await (_setup ??= _configure());
    await _controller.loadHtmlString(html, baseUrl: benchPageBaseUrl);
  }

  Future<void> _configure() async {
    final controller = _controller;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(const Color(0xFF0F1115));
    await controller.enableZoom(false);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) => NavigationDecision.prevent,
      ),
    );
    await controller.addJavaScriptChannel(
      benchChannelName,
      onMessageReceived: (message) => _add(_decode(message.message)),
    );
    await controller.setOnConsoleMessage((message) {
      final level = message.level;
      if (level == JavaScriptLogLevel.error ||
          level == JavaScriptLogLevel.warning) {
        _add({
          'type': 'console',
          'level': level.name,
          'message': message.message,
        });
      }
    });
    await controller.setOnJavaScriptAlertDialog((_) async {});
    await controller.setOnJavaScriptConfirmDialog((_) async => false);
    await controller.setOnJavaScriptTextInputDialog((_) async => '');
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      await AndroidWebViewController.enableDebugging(kDebugMode);
      await platform.setAllowFileAccess(false);
      await platform.setAllowContentAccess(false);
      await platform.setGeolocationEnabled(false);
      await platform.setMediaPlaybackRequiresUserGesture(true);
      await platform.setTextZoom(100);
    }
  }

  static Map<String, Object?>? _decode(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void _add(Map<String, Object?>? message) {
    if (message != null && !_messages.isClosed) {
      _messages.add(message);
    }
  }

  @override
  Future<void> execute(String script) => _controller.runJavaScript(script);

  @override
  Widget buildView(BuildContext context) =>
      WebViewWidget(controller: _controller);

  @override
  Future<void> dispose() async {
    // Broadcast close is safe to await (TESTING.md §1.2).
    await _messages.close();
  }
}
