/// Shared harness: pumps the real app over in-memory stores at a fixed
/// surface size, mirroring bootstrap's override wiring. The editor runs on
/// scripted pages (test/support/fake_editor_surface.dart): platform views
/// cannot run under `flutter test`. Files live in an in-memory workspace
/// (test/support/memory_file_service.dart): real I/O never completes in
/// testWidgets' fake async zone. Folders from shared storage come from a
/// fake storage broker (test/support/fake_storage_broker.dart), and
/// projects from in-memory project folders
/// (test/support/memory_project_storage.dart).
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/bench/editor_bench_providers.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/keyboard_state.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/design_system/theme/theme.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 exports Override from misc.dart, not the main library.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backup_service.dart';
import '../support/fake_bench_surface.dart';
import '../support/fake_editor_surface.dart';
import '../support/fake_hardware_keyboard.dart';
import '../support/fake_storage_broker.dart';
import '../support/memory_file_service.dart';
import '../support/memory_project_storage.dart';

final class TestHarness {
  TestHarness({
    AppSettings? settings,
    ShellState? shell,
    this.editorPageLoader,
    this.benchRunnerFactory,
    MemoryFileService? files,
    SessionStore? sessionStore,
    FakeHardwareKeyboard? hardwareKeyboard,
    FakeBackupService? backup,
    this.broker,
    MemoryProjectStorage? projects,
  }) : settingsStore = InMemorySettingsStore(
         settings ?? const AppSettings(welcomeSeen: true),
       ),
       shellStore = InMemoryShellStateStore(shell),
       files = files ?? MemoryFileService(),
       sessionStore = sessionStore ?? MemorySessionStore(),
       hardwareKeyboard = hardwareKeyboard ?? FakeHardwareKeyboard(),
       backup = backup ?? FakeBackupService(),
       projects = projects ?? MemoryProjectStorage();

  final InMemorySettingsStore settingsStore;
  final InMemoryShellStateStore shellStore;

  /// The workspace, shared by every app this harness pumps (a second
  /// [app] is a restart over the same files).
  final MemoryFileService files;

  /// Tabs and the hot-exit journal, shared the same way: a second [app]
  /// without a pause first is the app after process death.
  final SessionStore sessionStore;

  /// Whether a hardware keyboard is attached (none unless a test says so).
  final FakeHardwareKeyboard hardwareKeyboard;

  /// Android's backup switch (off, available, never run, unless a test
  /// says otherwise).
  final FakeBackupService backup;

  /// Folders from shared storage. With one, [files] is the built-in
  /// project's alone and the app switches between workspaces as it does
  /// on a device; without, [files] is every workspace's.
  final FakeStorageBroker? broker;

  /// The projects' folders besides the demo project's ([files]), shared
  /// like [files] by every app this harness pumps.
  final MemoryProjectStorage projects;

  /// Replaces the stand-in editor page (null: a page that always loads).
  final EditorPageLoader? editorPageLoader;

  /// The editor benchmark screen's runner (default: a build without
  /// benchmark pages, so no test ever reaches a real WebView or asset).
  final EditorBenchRunnerFactory? benchRunnerFactory;

  /// Every scripted editor page created through this harness, newest last.
  final List<FakeEditorSurface> editorSurfaces = [];

  /// The page behind the current app.
  FakeEditorSurface get editorSurface => editorSurfaces.last;

  List<Override> _overrides() => [
    settingsStoreProvider.overrideWithValue(settingsStore),
    shellStateStoreProvider.overrideWithValue(shellStore),
    if (broker case final broker?) ...[
      projectFileServiceProvider.overrideWithValue(files),
      storageBrokerProvider.overrideWithValue(broker),
    ] else ...[
      fileServiceProvider.overrideWithValue(files),
      storageBrokerProvider.overrideWithValue(FakeStorageBroker()),
    ],
    projectStorageProvider.overrideWithValue(projects),
    sessionStoreProvider.overrideWithValue(sessionStore),
    hardwareKeyboardSourceProvider.overrideWithValue(hardwareKeyboard),
    backupServiceProvider.overrideWithValue(backup),
    ...fakeEditorOverrides(editorSurfaces.add, editorPageLoader),
    editorBenchRunnerFactoryProvider.overrideWithValue(
      benchRunnerFactory ?? fakeBenchRunnerFactory(),
    ),
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

/// Navigates: home → demo workspace, settling all frames. Home's list
/// scrolls to the demo project's button first: on short surfaces it sits
/// below New Project and Open Folder (Phase 3 W3).
Future<void> openDemoWorkspace(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('explore_demo'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}
