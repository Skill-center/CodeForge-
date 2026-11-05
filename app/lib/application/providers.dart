/// App-wide dependency wiring (docs/ARCHITECTURE.md §2.2).
///
/// Stores are seeded synchronously at bootstrap and injected via overrides,
/// so the first frame already shows restored state — no loading flash.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/contracts.dart';
import '../services/fakes.dart';
import '../services/settings/settings_store.dart';
import '../services/shell/shell_state.dart';

/// Overridden in bootstrap with the real prefs-backed store.
final settingsStoreProvider = Provider<SettingsStore>((ref) {
  throw StateError('settingsStoreProvider must be overridden at bootstrap');
});

/// Overridden in bootstrap with the real prefs-backed store.
final shellStateStoreProvider = Provider<ShellStateStore>((ref) {
  throw StateError('shellStateStoreProvider must be overridden at bootstrap');
});

final fileServiceProvider = Provider<FileService>((ref) {
  ref.keepAlive();
  return FakeFileService();
});

final editorServiceProvider = Provider<FakeEditorService>((ref) {
  ref.keepAlive();
  final files = ref.watch(fileServiceProvider);
  return FakeEditorService(files as FakeFileService);
});

final terminalServiceProvider = Provider<TerminalService>((ref) {
  return FakeTerminalService();
});

final runtimeServiceProvider = Provider<RuntimeService>((ref) {
  return FakeRuntimeService();
});

final gitServiceProvider = Provider<GitService>((ref) {
  return FakeGitService();
});

final searchServiceProvider = Provider<SearchService>((ref) {
  final files = ref.watch(fileServiceProvider);
  return FakeSearchService(files as FakeFileService);
});
