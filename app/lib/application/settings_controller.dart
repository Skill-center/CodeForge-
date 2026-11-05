/// Settings controller: synchronous Notifier seeded from the store,
/// write-through persistence on every mutation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/logger.dart';
import '../services/settings/settings_model.dart';
import 'providers.dart';

final class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    // Riverpod 3 auto-disposes by default; settings must live for the app's
    // lifetime so debounced/pending writes are never dropped.
    ref.keepAlive();
    return ref.watch(settingsStoreProvider).load();
  }

  Future<void> _persist(AppSettings next) async {
    state = next;
    try {
      await ref.read(settingsStoreProvider).save(next);
    } on Object catch (error) {
      // Persistence failure must not lose the in-memory state or crash.
      appLogger.error(
        'settings',
        'persist_failed',
        fields: {'error': '$error'},
      );
    }
  }

  Future<void> setThemeMode(ThemeMode mode) =>
      _persist(state.copyWith(themeMode: mode));

  Future<void> setEditorFontSize(double size) => _persist(
    state.copyWith(editorFontSize: size.clamp(10.0, 24.0).toDouble()),
  );

  Future<void> setReducedMotion(bool value) =>
      _persist(state.copyWith(reducedMotion: value));

  Future<void> setToolbarPreset(ToolbarPreset preset) =>
      _persist(state.copyWith(toolbarPreset: preset));

  Future<void> setWelcomeSeen() => _persist(state.copyWith(welcomeSeen: true));

  Future<void> setShowHiddenFiles(bool value) =>
      _persist(state.copyWith(showHiddenFiles: value));
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
