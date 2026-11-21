/// Riverpod wiring for the terminal page (Phase 5 W3). Tests override the
/// surface factory and the page loader with a scripted page
/// (test/support/fake_terminal_surface.dart).
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/editor/editor_surface.dart';
import '../../services/editor/webview_editor_surface.dart';
import '../../services/terminal/terminal_page.dart';
import 'terminal_view.dart';

/// Creates the WebView the terminal page runs in: one for every session.
/// Output reaches it through a MessagePort (Phase 5 W6, page_port.dart).
final terminalSurfaceFactoryProvider = Provider<EditorSurface Function()>(
  (ref) =>
      () => WebViewEditorSurface(baseUrl: terminalPageBaseUrl, hostPort: true),
);

/// Loads the bundled terminal page and verifies it against its manifest.
final terminalPageLoaderProvider = Provider<TerminalPageLoader>(
  (ref) =>
      () => loadTerminalPage(rootBundle),
);

/// The one terminal page. It lives as long as the app, like the sessions:
/// it loads when the first terminal starts, not before.
final terminalViewProvider = Provider<TerminalView>((ref) {
  final view = TerminalView(
    surface: ref.watch(terminalSurfaceFactoryProvider)(),
    loadPage: ref.watch(terminalPageLoaderProvider),
  );
  ref.onDispose(() => unawaited(view.dispose()));
  return view;
});
