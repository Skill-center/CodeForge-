/// Shared harness: pumps the real app over in-memory stores at a fixed
/// surface size, mirroring bootstrap's override wiring.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class TestHarness {
  TestHarness({AppSettings? settings, ShellState? shell})
    : settingsStore = InMemorySettingsStore(
        settings ?? const AppSettings(welcomeSeen: true),
      ),
      shellStore = InMemoryShellStateStore(shell);

  final InMemorySettingsStore settingsStore;
  final InMemoryShellStateStore shellStore;

  Widget app() {
    return ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(settingsStore),
        shellStateStoreProvider.overrideWithValue(shellStore),
      ],
      child: const CodeForgeApp(),
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
