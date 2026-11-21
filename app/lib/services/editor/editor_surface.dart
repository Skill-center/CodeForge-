/// The surface the editor page runs in (docs/EDITOR_ARCHITECTURE.md §2).
///
/// The app reaches the page only through this interface: one channel in
/// each direction, carrying protocol v1 JSON strings. Production uses
/// [WebViewEditorSurface] (webview_editor_surface.dart); widget tests use a
/// scripted Dart page (test/support/fake_editor_surface.dart).
library;

import 'package:flutter/widgets.dart';

/// Something the surface observed outside the message channel.
sealed class EditorSurfaceEvent {
  const EditorSurfaceEvent();
}

/// The document finished loading; the page still has to announce
/// `editor.ready` before it accepts requests.
final class SurfacePageLoaded extends EditorSurfaceEvent {
  const SurfacePageLoaded();
}

/// A resource failed to load. The page makes no requests, so any of these
/// is unexpected and worth a log line.
final class SurfaceLoadFailed extends EditorSurfaceEvent {
  const SurfaceLoadFailed(this.description);

  final String description;
}

/// The page tried to navigate and was refused.
final class SurfaceNavigationBlocked extends EditorSurfaceEvent {
  const SurfaceNavigationBlocked(this.url);

  final String url;
}

/// A console line from the page (diagnostics only).
final class SurfaceConsoleMessage extends EditorSurfaceEvent {
  const SurfaceConsoleMessage({required this.level, required this.message});

  final String level;
  final String message;
}

abstract interface class EditorSurface {
  /// Raw messages the page posted, in order, unvalidated.
  Stream<String> get messages;

  /// Observations outside the channel: loads, refused navigations, console.
  Stream<EditorSurfaceEvent> get events;

  /// The Chromium major version of the engine the page runs in (the
  /// WebView's), or null when the surface can't tell. The host checks it
  /// against the page's floor before loading it (core/editor/webview_floor).
  Future<int?> engineMajorVersion();

  /// Loads [html] as the page. Completes once loading has started.
  Future<void> loadPage(String html);

  /// Hands one serialized host message to the page.
  Future<void> deliver(String message);

  /// The page holds the port the surface posted it as it loaded (Phase 5
  /// W6; the terminal page says so in `terminal.ready`): until the page
  /// loads again, [deliver] sends through that port rather than as one
  /// script per message. Answers whether the surface has such a port;
  /// without one nothing changes.
  bool usePagePort();

  /// Reloads the page; the host then rebuilds it from its shadows.
  Future<void> reload();

  /// The widget that shows the page.
  Widget buildView(BuildContext context);

  /// Releases the surface; nothing may be called afterwards.
  Future<void> dispose();
}
