/// Riverpod wiring for the editor host. Tests override the surface factory
/// and the page loader with a scripted fake (test/support/).
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/editor/editor_page.dart';
import '../../services/editor/editor_surface.dart';
import '../../services/editor/webview_editor_surface.dart';
import 'editor_host.dart';

/// Creates the platform surface the page runs in.
final editorSurfaceFactoryProvider = Provider<EditorSurface Function()>(
  (ref) => WebViewEditorSurface.new,
);

/// Loads the bundled page and verifies it against its manifest.
final editorPageLoaderProvider = Provider<EditorPageLoader>(
  (ref) =>
      () => loadEditorPage(rootBundle),
);

/// The one editor host. It lives as long as the app (a plain Provider is
/// never auto-disposed): the page and its documents survive navigation away
/// from the workbench and back.
final editorHostProvider = Provider<EditorHost>((ref) {
  final host = EditorHost(
    surface: ref.watch(editorSurfaceFactoryProvider)(),
    loadPage: ref.watch(editorPageLoaderProvider),
  );
  ref.onDispose(() => unawaited(host.dispose()));
  return host;
});

/// The host's status, for the editor pane's loading and error states.
final editorHostStatusProvider =
    NotifierProvider<EditorHostStatusNotifier, EditorHostStatus>(
      EditorHostStatusNotifier.new,
    );

final class EditorHostStatusNotifier extends Notifier<EditorHostStatus> {
  @override
  EditorHostStatus build() {
    final host = ref.watch(editorHostProvider);
    final subscription = host.statusChanges.listen((status) => state = status);
    ref.onDispose(() => unawaited(subscription.cancel()));
    return host.status;
  }
}
