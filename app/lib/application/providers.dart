/// App-wide dependency wiring (docs/ARCHITECTURE.md §2.2).
///
/// Stores are seeded synchronously at bootstrap and injected via overrides,
/// so the first frame already shows restored state — no loading flash.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/files/workspace_location.dart';
import '../services/contracts.dart';
import '../services/fakes.dart';
import '../services/files/local_file_service.dart';
import '../services/files/native/pigeon_storage_broker.dart';
import '../services/files/project_storage.dart';
import '../services/files/saf_file_service.dart';
import '../services/files/storage_broker.dart';
import '../services/platform/app_directories.dart';
import '../services/platform/backup_channel.dart';
import '../services/settings/settings_store.dart';
import '../services/shell/shell_state.dart';
import '../services/storage/app_database.dart';
import '../services/storage/drift_session_store.dart';
import '../services/storage/session_store.dart';
import 'shell_controller.dart';

/// Overridden in bootstrap with the real prefs-backed store.
final settingsStoreProvider = Provider<SettingsStore>((ref) {
  throw StateError('settingsStoreProvider must be overridden at bootstrap');
});

/// Overridden in bootstrap with the real prefs-backed store.
final shellStateStoreProvider = Provider<ShellStateStore>((ref) {
  throw StateError('shellStateStoreProvider must be overridden at bootstrap');
});

/// Where the open workspace lives: the project or folder the shell
/// remembers (Phase 3 W2, W3), or the demo project before any opened.
/// Changed through the workspace switcher (workspace_switcher.dart), which
/// stores the open documents first.
final currentWorkspaceProvider = Provider<WorkspaceLocation>((ref) {
  final workspace = ref.watch(
    shellControllerProvider.select((s) => s.workspace),
  );
  return workspace ?? const DemoProjectLocation();
});

/// The open workspace's files: a project's in app-private storage, or a
/// folder's through the storage broker. Tests override this with an
/// in-memory service (or override [projectFileServiceProvider],
/// [projectStorageProvider] and [storageBrokerProvider] to switch between
/// workspaces).
final fileServiceProvider = Provider<FileService>((ref) {
  ref.keepAlive();
  return switch (ref.watch(currentWorkspaceProvider)) {
    final ProjectLocation project when project.isDemo => ref.watch(
      projectFileServiceProvider,
    ),
    final ProjectLocation project =>
      ref.watch(projectStorageProvider).files(project),
    final FolderLocation folder => SafFileService(
      broker: ref.watch(storageBrokerProvider),
      folder: folder,
    ),
  };
});

/// The demo project's real files in app-private storage. The folder is
/// looked up (and seeded) on first use, not at bootstrap, so it never
/// delays the first frame.
final projectFileServiceProvider = Provider<FileService>((ref) {
  ref.keepAlive();
  return LocalFileService(rootPath: demoWorkspacePath);
});

/// The projects' folders, `<filesDir>/workspaces/<name>` (Phase 3 W3):
/// created, renamed and deleted from Home, and each project's file
/// service. Tests override this with an in-memory one.
final projectStorageProvider = Provider<ProjectStorage>((ref) {
  return LocalProjectStorage(rootPath: projectsRootPath);
});

/// Folders from shared storage, through the Kotlin storage broker
/// (docs/SECURITY.md §4.1). Without a host (`flutter test`) every call
/// fails as unsupported; tests override this with a fake.
final storageBrokerProvider = Provider<StorageBroker>((ref) {
  return PigeonStorageBroker();
});

/// Where the folder picker opens: null lets Android choose. The emulator
/// gate starts it in its test folder.
final folderPickerStartProvider = Provider<String?>((ref) => null);

/// Tabs, their cursor and scroll, and the hot-exit journal, in the app
/// database (ADR-0008). Like the workspace folder, the database opens on
/// first use, not at bootstrap. Tests override this with a
/// [MemorySessionStore].
final sessionStoreProvider = Provider<SessionStore>((ref) {
  ref.keepAlive();
  final store = DriftSessionStore(
    AppDatabase(openAppDatabase(applicationFilesPath)),
  );
  ref.onDispose(() => unawaited(store.close()));
  return store;
});

/// Android's backup switch (ADR-0012), over the host's channel. Tests
/// override this with a fake; without a host it reports itself unavailable.
final backupServiceProvider = Provider<BackupService>((ref) {
  return const ChannelBackupService();
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
