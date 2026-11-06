/// App-wide dependency wiring (docs/ARCHITECTURE.md §2.2).
///
/// Stores are seeded synchronously at bootstrap and injected via overrides,
/// so the first frame already shows restored state — no loading flash.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/contracts.dart';
import '../services/fakes.dart';
import '../services/files/local_file_service.dart';
import '../services/platform/app_directories.dart';
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

/// Real files in the app-private workspace folder. The folder is looked up
/// (and seeded) on first use, not at bootstrap, so it never delays the
/// first frame. Tests override this with an in-memory service.
final fileServiceProvider = Provider<FileService>((ref) {
  ref.keepAlive();
  return LocalFileService(rootPath: demoWorkspacePath);
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
  return FakeSearchService(ref.watch(fileServiceProvider));
});
