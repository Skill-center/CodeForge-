/// The language servers of the open workspace (Phase 6 W4, W5;
/// PHASE_6_PLAN): one client per server (application/lsp/language_client.dart),
/// fed by the editor and the documents, for the status strip's chip and the
/// editor's features (application/lsp/lsp_features.dart).
///
/// - **When:** servers run once the Linux runtime is ready, on a host that
///   has them (Android), for the languages turned on in Settings → Editor.
/// - **Where:** a project's folder; a folder from shared storage through its
///   copy (ADR-0013, Phase 6 W5), brought up to date before any server
///   starts and again after each save, each change from outside the app and
///   each file a rename writes. The documents' paths are the same in the
///   copy, so a place in it is a place in the folder's document.
/// - **Documents:** a document is shown to its server when it is first
///   activated, and again at each activation (a server stopped to free
///   memory starts again with it). Its edits follow it (EditorHost's
///   DocumentEdited), its saves too (its stamp moves while it is not
///   dirty), and it is closed with its tab, or when Save As gives it a name
///   another server or none analyses.
/// - **Files changed outside the app:** each folder Phase 3's watcher lists
///   again is compared with its last listing, and what was created, deleted
///   or changed in size goes to the servers that asked
///   (`didChangeWatchedFiles`).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/files/workspace_location.dart';
import '../../core/logging/logger.dart';
import '../../core/lsp/lsp_models.dart';
import '../../services/contracts.dart';
import '../../services/files/storage_broker.dart';
import '../../services/runtime/runtime_service.dart';
import '../documents/document_controller.dart';
import '../documents/document_state.dart';
import '../editor/editor_host.dart';
import '../editor/editor_providers.dart';
import '../providers.dart';
import '../runtime_controller.dart';
import '../settings_controller.dart';
import 'language_client.dart';
import 'lsp_clock.dart';

const String _tag = 'lsp';

/// The language servers turned on in Settings → Editor (Phase 6 W5).
final enabledLanguageServersProvider = Provider<Set<LspServerId>>((ref) {
  final settings = ref.watch(settingsControllerProvider);
  return {
    if (settings.pythonServer) LspServerId.pyright,
    if (settings.typescriptServer) LspServerId.typescript,
  };
});

/// Whether the app runs language servers at all: while one is on in
/// Settings → Editor (Phase 6 W5, in place of W4's fixed default). The phase
/// gate's other groups and Test Lab's tests turn them off, so what they
/// measure stays as it was; the gate's `lsp` group leaves them on.
final languageServersEnabledProvider = Provider<bool>(
  (ref) => ref.watch(enabledLanguageServersProvider).isNotEmpty,
);

/// The clock the language clients run on; tests use their own.
final lspClockProvider = Provider<LspClock>((ref) => const SystemLspClock());

/// How the language clients pace themselves; tests shorten it.
final lspClientSettingsProvider = Provider<LspClientSettings>(
  (ref) => const LspClientSettings(),
);

/// How long the copy waits for more changes before it is brought up to
/// date: a save and the listing it causes come together.
const Duration copyRefreshDelay = Duration(milliseconds: 300);

/// The language servers, as the status strip shows them.
final class LspState {
  const LspState({
    this.available = false,
    this.offReason,
    this.statuses = const {},
    this.enabledServers = const {},
  });

  /// Servers can run here: a host that has them, and one turned on. The
  /// status strip shows no server chip otherwise.
  final bool available;

  /// Why none runs now (the runtime is not ready, the folder is being
  /// copied), or null.
  final String? offReason;

  /// The state of each server that has a client.
  final Map<LspServerId, LspStatus> statuses;

  /// The servers turned on in Settings → Editor.
  final Set<LspServerId> enabledServers;

  /// Whether [server] is turned on.
  bool isOn(LspServerId server) => enabledServers.contains(server);

  /// [server]'s state: its client's, or off with [offReason].
  LspStatus statusOf(LspServerId server) {
    if (!isOn(server)) {
      return const LspStatus(
        LspPhase.off,
        reason: 'Turned off in Settings → Editor',
      );
    }
    return statuses[server] ??
        (offReason == null
            ? LspStatus.off
            : LspStatus(LspPhase.off, reason: offReason));
  }

  LspState withStatus(LspServerId server, LspStatus status) => LspState(
    available: available,
    offReason: offReason,
    statuses: {...statuses, server: status},
    enabledServers: enabledServers,
  );

  LspState withOffReason(String? reason) => LspState(
    available: available,
    offReason: reason,
    statuses: statuses,
    enabledServers: enabledServers,
  );
}

final lspControllerProvider = NotifierProvider<LspController, LspState>(
  LspController.new,
);

final class LspController extends Notifier<LspState> {
  Map<LspServerId, LanguageClient> _clients = {};

  /// The documents shown to a server, by docId: which server, under which
  /// path.
  Map<String, ({LspServerId server, String path})> _shown = {};

  /// Each folder's last listing: names, and sizes (-1 for folders).
  Map<String, Map<String, int>> _listings = {};
  List<StreamSubscription<LspStatus>> _statusSubscriptions = [];
  LspWorkspace? _workspace;
  Set<LspServerId> _enabledServers = const {};

  /// The folder whose copy the servers read, in a folder workspace.
  FolderLocation? _folder;

  /// Changes waiting for the copy to be brought up to date, then for the
  /// servers.
  List<LspFileChange> _pendingChanges = [];
  Timer? _copyTimer;
  bool _copyRunning = false;
  bool _enabled = false;

  /// Grows with every build: what an older build scheduled is stale.
  int _build = 0;

  @override
  LspState build() {
    final service = ref.watch(lspServiceProvider);
    final enabled = ref.watch(languageServersEnabledProvider);
    final available = service.available && enabled;
    final enabledServers = ref.watch(enabledLanguageServersProvider);
    final location = ref.watch(currentWorkspaceProvider);
    final runtimeReady = ref.watch(
      runtimeControllerProvider.select((s) => s.state == RuntimeState.ready),
    );
    final clock = ref.watch(lspClockProvider);
    final settings = ref.watch(lspClientSettingsProvider);
    final host = ref.watch(editorHostProvider);
    _build += 1;
    final build = _build;
    final clients = <LspServerId, LanguageClient>{};
    final subscriptions = <StreamSubscription<LspStatus>>[];
    _clients = clients;
    _statusSubscriptions = subscriptions;
    _shown = {};
    _listings = {};
    _pendingChanges = [];
    _copyRunning = false;
    _enabledServers = enabledServers;
    _folder = location is FolderLocation ? location : null;
    final workspace = switch (location) {
      ProjectLocation(:final folder) => LspWorkspace.project(folder),
      FolderLocation(:final id) => LspWorkspace.copy(id),
    };
    _workspace = workspace;
    _service = service;
    _clock = clock;
    _settings = settings;
    final copyFirst = _folder != null;
    final offReason = !runtimeReady
        ? 'The Linux runtime is not ready'
        : copyFirst
        ? 'Copying the folder for analysis'
        : null;
    final listening = available && runtimeReady;
    _enabled = listening && !copyFirst;
    ref.onDispose(() {
      // Whatever this build scheduled finds itself stale.
      _build += 1;
      _enabled = false;
      _copyTimer?.cancel();
      _copyTimer = null;
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      for (final client in clients.values) {
        unawaited(client.dispose());
      }
    });
    if (listening) {
      final edits = host.events.listen(_onEditorEvent);
      ref.onDispose(() => unawaited(edits.cancel()));
      ref.listen<DocumentsState>(documentControllerProvider, _onDocuments);
      scheduleMicrotask(() {
        if (build != _build) {
          return;
        }
        if (copyFirst) {
          unawaited(_firstCopy(build));
        } else {
          _onDocuments(null, ref.read(documentControllerProvider));
        }
      });
    }
    return LspState(
      available: available,
      offReason: offReason,
      enabledServers: enabledServers,
    );
  }

  late LspService _service;
  late LspClock _clock;
  late LspClientSettings _settings;

  /// [server]'s client, while it has one (W5's features ask through it).
  LanguageClient? clientFor(LspServerId server) => _clients[server];

  /// Every client there is now.
  Map<LspServerId, LanguageClient> get clients => Map.unmodifiable(_clients);

  /// The user's *Restart* on the chip, or in Settings → Linux runtime.
  Future<void> restart(LspServerId server) async {
    await _clients[server]?.restart();
  }

  /// Phase 3's watcher listed [folder] again (file_watch_controller.dart):
  /// what changed since its last listing goes to the servers (through the
  /// copy, in a folder workspace). A folder's first listing is only
  /// remembered.
  void folderListed(String folder, List<FileEntry> entries) {
    if (!_enabled) {
      return;
    }
    final now = <String, int>{
      for (final entry in entries)
        entry.name: entry.isDirectory ? -1 : (entry.sizeBytes ?? -2),
    };
    final before = _listings[folder];
    _listings[folder] = now;
    if (before == null || _clients.isEmpty) {
      return;
    }
    String pathOf(String name) => folder.isEmpty ? name : '$folder/$name';
    final changes = <LspFileChange>[
      for (final MapEntry(key: name, value: size) in now.entries)
        if (!before.containsKey(name))
          LspFileChange(pathOf(name), LspFileChangeType.created)
        else if (size >= 0 && before[name] != size)
          LspFileChange(pathOf(name), LspFileChangeType.changed),
      for (final name in before.keys)
        if (!now.containsKey(name))
          LspFileChange(pathOf(name), LspFileChangeType.deleted),
    ];
    _changed(changes);
  }

  /// Phase 3's watcher found [folder] gone.
  void folderGone(String folder) {
    final before = _listings.remove(folder);
    _listings.removeWhere((key, _) => key.startsWith('$folder/'));
    if (!_enabled || before == null || folder.isEmpty) {
      return;
    }
    _changed([LspFileChange(folder, LspFileChangeType.deleted)]);
  }

  /// A rename wrote [paths] (Phase 6 W5): the servers read them again,
  /// from the copy once it has them in a folder workspace.
  void filesWritten(List<String> paths) {
    if (!_enabled || paths.isEmpty) {
      return;
    }
    _changed([
      for (final path in paths) LspFileChange(path, LspFileChangeType.changed),
    ]);
  }

  /// Sends [changes] to the servers: now in a project, after the copy is
  /// brought up to date in a folder.
  void _changed(List<LspFileChange> changes) {
    if (changes.isEmpty) {
      return;
    }
    if (_folder != null) {
      _refreshCopy(changes);
      return;
    }
    for (final client in _clients.values) {
      client.filesChanged(changes);
    }
  }

  // ---------------------------------------------------- the folder's copy

  /// Brings the folder's copy up to date before any server starts in it.
  Future<void> _firstCopy(int build) async {
    final folder = _folder;
    if (folder == null) {
      return;
    }
    final started = DateTime.now();
    final synced = await ref
        .read(storageBrokerProvider)
        .syncCopy(folder.treeUri, folder.id);
    if (build != _build) {
      return;
    }
    switch (synced) {
      case Err<CopySummary>(:final failure):
        appLogger.warn(_tag, 'copy_failed', fields: {'error': failure.message});
        state = state.withOffReason(
          'The folder could not be copied for analysis: ${failure.message}',
        );
      case Ok<CopySummary>(:final value):
        appLogger.info(
          _tag,
          'copy_ready',
          fields: {
            'files': value.files,
            'copied': value.copied,
            'leftOut': value.leftOut,
            'ms': DateTime.now().difference(started).inMilliseconds,
          },
        );
        if (value.stopped) {
          state = state.withOffReason('The copy for analysis was cancelled');
          return;
        }
        _enabled = true;
        state = state.withOffReason(null);
        _onDocuments(null, ref.read(documentControllerProvider));
    }
  }

  /// Queues [changes] for the servers, after the copy takes them.
  void _refreshCopy(List<LspFileChange> changes) {
    _pendingChanges = [..._pendingChanges, ...changes];
    _copyTimer?.cancel();
    final build = _build;
    _copyTimer = Timer(copyRefreshDelay, () => unawaited(_runRefresh(build)));
  }

  Future<void> _runRefresh(int build) async {
    final folder = _folder;
    if (build != _build || !_enabled || folder == null) {
      return;
    }
    if (_copyRunning) {
      // One at a time: this one follows the copy that runs.
      _copyTimer = Timer(copyRefreshDelay, () => unawaited(_runRefresh(build)));
      return;
    }
    final changes = _pendingChanges;
    _pendingChanges = [];
    _copyRunning = true;
    final Result<CopySummary> synced;
    try {
      synced = await ref
          .read(storageBrokerProvider)
          .syncCopy(folder.treeUri, folder.id);
    } finally {
      if (build == _build) {
        _copyRunning = false;
      }
    }
    if (build != _build || !_enabled) {
      return;
    }
    if (synced case Err<CopySummary>(:final failure)) {
      appLogger.warn(
        _tag,
        'copy_refresh_failed',
        fields: {'error': failure.message},
      );
    }
    if (changes.isEmpty) {
      return;
    }
    for (final client in _clients.values) {
      client.filesChanged(changes);
    }
  }

  // ------------------------------------------------------------ documents

  void _onDocuments(DocumentsState? previous, DocumentsState next) {
    if (!_enabled) {
      return;
    }
    final byDocId = <String, OpenDocument>{
      for (final doc in next.documents.values) doc.docId: doc,
    };
    // Closed, renamed, or no longer of a server's languages.
    for (final MapEntry(key: docId, value: shown) in _shown.entries.toList()) {
      final doc = byDocId[docId];
      final server = doc == null ? null : _serverFor(doc);
      if (doc == null || server != shown.server || doc.path != shown.path) {
        _shown.remove(docId);
        _clients[shown.server]?.close(shown.path);
      }
    }
    // Saved: its stamp moved while it is not dirty.
    if (previous != null) {
      final saved = <String>[];
      for (final MapEntry(key: docId, value: shown) in _shown.entries) {
        final doc = byDocId[docId];
        final before = previous.documents[shown.path];
        if (doc != null &&
            before != null &&
            before.docId == docId &&
            before.stamp != doc.stamp &&
            !doc.dirty) {
          _clients[shown.server]?.saved(shown.path);
          saved.add(shown.path);
        }
      }
      // The copy takes the saved file, for when it is closed and read
      // from disk again.
      if (saved.isNotEmpty && _folder != null) {
        _refreshCopy([
          for (final path in saved)
            LspFileChange(path, LspFileChangeType.changed),
        ]);
      }
    }
    // Shown: the active document, when activated. The editor takes a new
    // document just after its tab appears, so this waits a microtask.
    final active = next.documents[next.activePath];
    if (active != null &&
        (previous?.activePath != next.activePath ||
            !_shown.containsKey(active.docId))) {
      final docId = active.docId;
      final build = _build;
      scheduleMicrotask(() {
        if (build != _build || !_enabled) {
          return;
        }
        final current = ref.read(documentControllerProvider);
        final doc = current.documents[current.activePath];
        if (doc != null && doc.docId == docId) {
          _show(doc);
        }
      });
    }
  }

  /// The server that analyses [doc], if it is turned on.
  LspServerId? _serverFor(OpenDocument doc) {
    if (doc.largeFile) {
      return null;
    }
    final server = LspServerId.forLanguage(doc.language);
    return server != null && _enabledServers.contains(server) ? server : null;
  }

  void _show(OpenDocument doc) {
    final server = _serverFor(doc);
    final workspace = _workspace;
    if (server == null || workspace == null) {
      return;
    }
    final host = ref.read(editorHostProvider);
    final text = host.textOf(doc.docId);
    final version = host.versionOf(doc.docId);
    if (text == null || version == null) {
      return;
    }
    final client = _clients[server] ?? _newClient(server, workspace);
    _shown[doc.docId] = (server: server, path: doc.path);
    client.open(doc.path, language: doc.language, version: version, text: text);
  }

  void _onEditorEvent(EditorHostEvent event) {
    if (!_enabled || event is! DocumentEdited) {
      return;
    }
    final shown = _shown[event.docId];
    final client = shown == null ? null : _clients[shown.server];
    if (shown == null || client == null) {
      return;
    }
    final change = event.change;
    if (change != null &&
        client.applyEdit(
          shown.path,
          baseVersion: change.baseVersion,
          version: change.version,
          changes: change.changes,
        )) {
      return;
    }
    // The whole text: a resync, a reload, or an edit the client missed.
    final host = ref.read(editorHostProvider);
    final text = host.textOf(event.docId);
    final version = host.versionOf(event.docId);
    if (text != null && version != null) {
      client.replaceText(shown.path, version: version, text: text);
    }
  }

  LanguageClient _newClient(LspServerId server, LspWorkspace workspace) {
    final client = LanguageClient(
      server: server,
      workspace: workspace,
      service: _service,
      clock: _clock,
      settings: _settings,
    );
    _clients[server] = client;
    final build = _build;
    _statusSubscriptions.add(
      client.statusChanges.listen((status) {
        if (build == _build) {
          state = state.withStatus(server, status);
        }
      }),
    );
    state = state.withStatus(server, client.status);
    return client;
  }
}
