/// [EditorSurface] on the Android System WebView (webview_flutter 4.14.1),
/// hardened as docs/SECURITY.md §3 describes.
///
/// webview_flutter_android does not expose `onRenderProcessGone`, so if the
/// WebView's renderer dies Android ends the app process, and the text comes
/// back from the edit journal on the next start (Phase 2 W5). Reloads short
/// of that are recovered in-app by the host (application/editor/).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'editor_surface.dart';

/// Base URL the page is loaded under. Nothing is fetched from it: the page
/// is one self-contained document whose CSP forbids every request.
const String editorPageBaseUrl =
    'https://appassets.androidplatform.net/editor/';

/// The one JavaScript channel the page posts through.
const String editorChannelName = 'CodeForgeBridge';

final class WebViewEditorSurface implements EditorSurface {
  WebViewEditorSurface() : _controller = WebViewController();

  final WebViewController _controller;
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<EditorSurfaceEvent> _events =
      StreamController<EditorSurfaceEvent>.broadcast();
  Future<void>? _setup;

  /// The verified page, kept for reloads.
  String? _html;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<EditorSurfaceEvent> get events => _events.stream;

  @override
  Future<void> loadPage(String html) async {
    _html = html;
    await (_setup ??= _configure());
    await _controller.loadHtmlString(html, baseUrl: editorPageBaseUrl);
  }

  /// Everything here happens before the first load: a JavaScript channel
  /// only takes effect for pages loaded after it was added.
  Future<void> _configure() async {
    final controller = _controller;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(const Color(0x00000000));
    await controller.enableZoom(false);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        // The page never navigates; anything that tries is refused.
        onNavigationRequest: (request) {
          _emit(SurfaceNavigationBlocked(request.url));
          return NavigationDecision.prevent;
        },
        onPageFinished: (_) => _emit(const SurfacePageLoaded()),
        onWebResourceError: (error) => _emit(
          SurfaceLoadFailed('${error.errorCode}: ${error.description}'),
        ),
      ),
    );
    await controller.addJavaScriptChannel(
      editorChannelName,
      onMessageReceived: (message) {
        if (!_messages.isClosed) {
          _messages.add(message.message);
        }
      },
    );
    await controller.setOnConsoleMessage(
      (message) => _emit(
        SurfaceConsoleMessage(
          level: message.level.name,
          message: message.message,
        ),
      ),
    );
    // The page never opens dialogs; refuse them should anything try.
    await controller.setOnJavaScriptAlertDialog((_) async {});
    await controller.setOnJavaScriptConfirmDialog((_) async => false);
    await controller.setOnJavaScriptTextInputDialog((_) async => '');
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      // Remote inspection (chrome://inspect) in debug builds only.
      await AndroidWebViewController.enableDebugging(kDebugMode);
      await platform.setAllowFileAccess(false);
      await platform.setAllowContentAccess(false);
      await platform.setGeolocationEnabled(false);
      await platform.setMediaPlaybackRequiresUserGesture(true);
      // The host sends a font size that already includes the user's text
      // scale (editor.configure); the WebView must not scale it again.
      await platform.setTextZoom(100);
    }
  }

  void _emit(EditorSurfaceEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  @override
  Future<void> deliver(String message) {
    // jsonEncode turns any message into a valid JavaScript string literal.
    return _controller.runJavaScript(
      'window.codeforge.receive(${jsonEncode(message)});',
    );
  }

  /// Loads the same verified page again: a fresh document and JavaScript
  /// context, whose `editor.ready` makes the host reopen everything. (Not
  /// WebViewController.reload(): for a page loaded from a string, that goes
  /// through the WebView's history entry instead of the bytes we verified.)
  @override
  Future<void> reload() async {
    final html = _html;
    if (html == null) {
      return;
    }
    await (_setup ??= _configure());
    await _controller.loadHtmlString(html, baseUrl: editorPageBaseUrl);
  }

  @override
  Widget buildView(BuildContext context) =>
      WebViewWidget(controller: _controller);

  @override
  Future<void> dispose() async {
    await _messages.close();
    await _events.close();
  }
}
