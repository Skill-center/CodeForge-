/// Shared harness: pumps the real app over in-memory stores at a fixed
/// surface size, mirroring bootstrap's override wiring. The editor runs on
/// scripted pages (test/support/fake_editor_surface.dart): platform views
/// cannot run under `flutter test`.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/design_system/theme/theme.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 exports Override from misc.dart, not the main library.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';

final class TestHarness {
  TestHarness({AppSettings? settings, ShellState? shell, this.editorPageLoader})
    : settingsStore = InMemorySettingsStore(
        settings ?? const AppSettings(welcomeSeen: true),
      ),
      shellStore = InMemoryShellStateStore(shell);

  final InMemorySettingsStore settingsStore;
  final InMemoryShellStateStore shellStore;

  /// Replaces the stand-in editor page (null: a page that always loads).
  final EditorPageLoader? editorPageLoader;

  /// Every scripted editor page created through this harness, newest last.
  final List<FakeEditorSurface> editorSurfaces = [];

  /// The page behind the current app.
  FakeEditorSurface get editorSurface => editorSurfaces.last;

  List<Override> _overrides() => [
    settingsStoreProvider.overrideWithValue(settingsStore),
    shellStateStoreProvider.overrideWithValue(shellStore),
    ...fakeEditorOverrides(editorSurfaces.add, editorPageLoader),
  ];

  Widget app() {
    return ProviderScope(overrides: _overrides(), child: const CodeForgeApp());
  }

  /// [child] alone under the app's dark theme, over the same stores and
  /// scripted editor pages as [app]: for one pane at sizes the whole
  /// workbench never gives it.
  Widget wrap(Widget child) {
    return ProviderScope(
      overrides: _overrides(),
      child: MaterialApp(
        theme: CfTheme.dark(),
        home: Scaffold(body: child),
      ),
    );
  }
}

/// Sets a logical-pixel surface (dpr 1.0) and registers cleanup.
void setSurface(WidgetTester tester, double width, double height) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

/// Navigates: home → demo workspace, settling all frames.
Future<void> openDemoWorkspace(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('explore_demo')));
  await tester.pumpAndSettle();
}
