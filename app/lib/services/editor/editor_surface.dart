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

  /// Loads [html] as the page. Completes once loading has started.
  Future<void> loadPage(String html);

  /// Hands one serialized host message to the page.
  Future<void> deliver(String message);

  /// Reloads the page; the host then rebuilds it from its shadows.
  Future<void> reload();

  /// The widget that shows the page.
  Widget buildView(BuildContext context);

  /// Releases the surface; nothing may be called afterwards.
  Future<void> dispose();
}
