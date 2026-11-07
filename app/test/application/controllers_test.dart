import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/settings_controller.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/memory_file_service.dart';

ProviderContainer _container({
  InMemorySettingsStore? settings,
  InMemoryShellStateStore? shell,
}) {
  return ProviderContainer.test(
    overrides: [
      settingsStoreProvider.overrideWithValue(
        settings ?? InMemorySettingsStore(),
      ),
      shellStateStoreProvider.overrideWithValue(
        shell ?? InMemoryShellStateStore(),
      ),
      fileServiceProvider.overrideWithValue(MemoryFileService()),
      sessionStoreProvider.overrideWithValue(MemorySessionStore()),
      ...fakeEditorOverrides(),
    ],
  );
}

void main() {
  group('SettingsController', () {
    test('mutations write through to the store', () async {
      final store = InMemorySettingsStore();
      final container = _container(settings: store);
      final notifier = container.read(settingsControllerProvider.notifier);

      await notifier.setThemeMode(ThemeMode.light);
      await notifier.setEditorFontSize(18);
      await notifier.setReducedMotion(true);
      await notifier.setToolbarPreset(ToolbarPreset.none);
      await notifier.setWelcomeSeen();

      expect(store.load().themeMode, ThemeMode.light);
      expect(store.load().editorFontSize, 18);
      expect(store.load().reducedMotion, isTrue);
      expect(store.load().toolbarPreset, ToolbarPreset.none);
      expect(store.load().welcomeSeen, isTrue);
    });

    test('a new container over the same store restores state', () async {
      final store = InMemorySettingsStore();
      final first = _container(settings: store);
      await first
          .read(settingsControllerProvider.notifier)
          .setThemeMode(ThemeMode.system);

      final second = _container(settings: store);
      expect(
        second.read(settingsControllerProvider).themeMode,
        ThemeMode.system,
      );
    });

    test('font size is clamped', () async {
      final container = _container();
      await container
          .read(settingsControllerProvider.notifier)
          .setEditorFontSize(99);
      expect(container.read(settingsControllerProvider).editorFontSize, 24);
    });
  });

  group('ShellController', () {
    test('flush persists immediately (pause path)', () async {
      final store = InMemoryShellStateStore();
      final container = _container(shell: store);
      final notifier = container.read(shellControllerProvider.notifier);

      notifier.setLastRoute('/workspace');
      notifier.setActivity(ShellActivity.search);
      notifier.setTerminalStop(TerminalStop.half);
      await notifier.flush();

      expect(store.load().lastRoute, '/workspace');
      expect(store.load().activity, ShellActivity.search);
      expect(store.load().terminalStop, TerminalStop.half);
    });

    test('debounced persist lands without an explicit flush', () async {
      final store = InMemoryShellStateStore();
      final container = _container(shell: store);
      container
          .read(shellControllerProvider.notifier)
          .setLastRoute('/settings');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(store.load().lastRoute, '/settings');
    });

    test('non-restorable routes are rejected', () {
      final container = _container();
      container
          .read(shellControllerProvider.notifier)
          .setLastRoute('/settings/gallery');
      expect(container.read(shellControllerProvider).lastRoute, '/');
    });

    test('layout survives container recreation', () async {
      final store = InMemoryShellStateStore();
      final first = _container(shell: store);
      first.read(shellControllerProvider.notifier)
        ..setSidebarWidth(320)
        ..setTerminalHeight(280);
      await first.read(shellControllerProvider.notifier).flush();

      final second = _container(shell: store);
      expect(second.read(shellControllerProvider).sidebarWidth, 320);
      expect(second.read(shellControllerProvider).terminalHeight, 280);
    });
  });
}
