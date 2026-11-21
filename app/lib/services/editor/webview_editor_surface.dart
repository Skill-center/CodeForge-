/// [EditorSurface] on the Android System WebView (webview_flutter 4.14.1),
/// hardened as docs/SECURITY.md §3 describes. The terminal page runs in one
/// too, with its own origin (Phase 5 W3), and since Phase 5 W6 receives the
/// host's messages through a MessagePort (page_port.dart).
///
/// How the WebView is composed into the app is the engine's: on Android 14
/// and later with Vulkan, the manifest's EnableHcpp has every platform view
/// composed by Hybrid Composition++, with no copy of the WebView into a
/// texture; elsewhere Flutter's default, a texture layer (TLHC). Phase 5 W6,
/// docs/TERMINAL_ARCHITECTURE.md §2.2.
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

import '../../core/editor/webview_floor.dart';
import 'editor_surface.dart';
import 'page_port.dart';

/// Base URL the page is loaded under. Nothing is fetched from it: the page
/// is one self-contained document whose CSP forbids every request.
const String editorPageBaseUrl =
    'https://appassets.androidplatform.net/editor/';

/// The terminal page's base URL (Phase 5 W3), the same way.
const String terminalPageBaseUrl =
    'https://appassets.androidplatform.net/terminal/';

/// The one JavaScript channel the page posts through.
const String editorChannelName = 'CodeForgeBridge';

final class WebViewEditorSurface implements EditorSurface {
  /// [baseUrl] is the page's origin: the editor's by default, the terminal
  /// page's for its own WebView (Phase 5 W3). Nothing is fetched from it.
  /// With [hostPort] (the terminal's, Phase 5 W6), each loaded page is
  /// posted a MessagePort, which [usePagePort] switches [deliver] to.
  WebViewEditorSurface({
    this.baseUrl = editorPageBaseUrl,
    this.hostPort = false,
    PagePorts ports = const PagePorts(),
  }) : _controller = WebViewController(),
       _ports = ports;

  final String baseUrl;
  final bool hostPort;
  final PagePorts _ports;
  final WebViewController _controller;
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<EditorSurfaceEvent> _events =
      StreamController<EditorSurfaceEvent>.broadcast();
  Future<void>? _setup;

  /// The verified page, kept for reloads.
  String? _html;

  /// Counts loads, so that a port opened for a page that was replaced
  /// meanwhile does not count for the next one.
  int _load = 0;

  /// The load the native side posted a port to, if any.
  int? _portLoad;

  /// Whether [deliver] sends through the port (the page said it holds it).
  bool _throughPort = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<EditorSurfaceEvent> get events => _events.stream;

  /// From the WebView's own user agent (WebSettings.getUserAgentString on
  /// Android), which names its Chromium version. Never throws: a WebView
  /// that can't answer is not refused.
  @override
  Future<int?> engineMajorVersion() async {
    try {
      return chromeMajorVersion(await _controller.getUserAgent());
    } on Object {
      return null;
    }
  }

  @override
  Future<void> loadPage(String html) async {
    _html = html;
    await (_setup ??= _configure());
    _startLoad();
    await _controller.loadHtmlString(html, baseUrl: baseUrl);
  }

  /// A new page: scripts again until it says it holds a new port.
  void _startLoad() {
    _load += 1;
    _throughPort = false;
  }

  /// The WebView's identifier for native code (webview_flutter_android's
  /// WebViewFlutterAndroidExternalApi), or null off Android.
  int? get _webViewId {
    final platform = _controller.platform;
    return platform is AndroidWebViewController
        ? platform.webViewIdentifier
        : null;
  }

  /// Posts the page that just loaded its port (Phase 5 W6). It must have
  /// loaded: the page's listener is set up while its script first runs.
  Future<void> _openPort() async {
    final id = _webViewId;
    if (id == null) {
      return;
    }
    final load = _load;
    final opened = await _ports.open(id, origin: Uri.parse(baseUrl).origin);
    if (opened && load == _load) {
      _portLoad = load;
    }
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
        onPageFinished: (_) {
          _emit(const SurfacePageLoaded());
          if (hostPort) {
            unawaited(_openPort());
          }
        },
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
    if (_throughPort) {
      final id = _webViewId;
      if (id != null) {
        return _ports.post(id, message);
      }
    }
    // jsonEncode turns any message into a valid JavaScript string literal.
    return _controller.runJavaScript(
      'window.codeforge.receive(${jsonEncode(message)});',
    );
  }

  @override
  bool usePagePort() {
    if (!hostPort || _portLoad != _load) {
      return false;
    }
    _throughPort = true;
    return true;
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
    _startLoad();
    await _controller.loadHtmlString(html, baseUrl: baseUrl);
  }

  @override
  Widget buildView(BuildContext context) =>
      WebViewWidget(controller: _controller);

  @override
  Future<void> dispose() async {
    _throughPort = false;
    final id = _webViewId;
    if (hostPort && id != null) {
      await _ports.close(id);
    }
    await _messages.close();
    await _events.close();
  }
}
