/// The language servers of the open workspace (Phase 6 W4; PHASE_6_PLAN W4):
/// one client per server (application/lsp/language_client.dart), fed by the
/// editor and the documents, for the status strip's chip and, from W5, the
/// editor's features.
///
/// - **When:** servers run in a project once the Linux runtime is ready, on
///   a host that has them (Android). Folders from shared storage follow with
///   W5, through their copies (ADR-0013).
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

import '../../core/files/workspace_location.dart';
import '../../core/lsp/lsp_models.dart';
import '../../services/contracts.dart';
import '../../services/runtime/runtime_service.dart';
import '../documents/document_controller.dart';
import '../documents/document_state.dart';
import '../editor/editor_host.dart';
import '../editor/editor_providers.dart';
import '../providers.dart';
import '../runtime_controller.dart';
import 'language_client.dart';
import 'lsp_clock.dart';

/// Whether the app runs language servers at all. The phase gate's other
/// groups and Test Lab's tests turn them off, so what they measure stays as
/// it was (W6's `lsp` group turns them on); W5 makes it a setting.
final languageServersEnabledProvider = Provider<bool>((ref) => true);

/// The clock the language clients run on; tests use their own.
final lspClockProvider = Provider<LspClock>((ref) => const SystemLspClock());

/// How the language clients pace themselves; tests shorten it.
final lspClientSettingsProvider = Provider<LspClientSettings>(
  (ref) => const LspClientSettings(),
);

/// The language servers, as the status strip shows them.
final class LspState {
  const LspState({
    this.available = false,
    this.offReason,
    this.statuses = const {},
  });

  /// Servers can run here: a host that has them, and not turned off. The
  /// status strip shows no server chip otherwise.
  final bool available;

  /// Why none runs now (the runtime is not ready, a folder workspace), or
  /// null.
  final String? offReason;

  /// The state of each server that has a client.
  final Map<LspServerId, LspStatus> statuses;

  /// [server]'s state: its client's, or off with [offReason].
  LspStatus statusOf(LspServerId server) =>
      statuses[server] ??
      (offReason == null
          ? LspStatus.off
          : LspStatus(LspPhase.off, reason: offReason));

  LspState withStatus(LspServerId server, LspStatus status) => LspState(
    available: available,
    offReason: offReason,
    statuses: {...statuses, server: status},
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
  bool _enabled = false;

  /// Grows with every build: what an older build scheduled is stale.
  int _build = 0;

  @override
  LspState build() {
    final service = ref.watch(lspServiceProvider);
    final enabled = ref.watch(languageServersEnabledProvider);
    final location = ref.watch(currentWorkspaceProvider);
    final runtimeReady = ref.watch(
      runtimeControllerProvider.select((s) => s.state == RuntimeState.ready),
    );
    final clock = ref.watch(lspClockProvider);
    final settings = ref.watch(lspClientSettingsProvider);
    final host = ref.watch(editorHostProvider);
    _build += 1;
    final clients = <LspServerId, LanguageClient>{};
    final subscriptions = <StreamSubscription<LspStatus>>[];
    _clients = clients;
    _statusSubscriptions = subscriptions;
    _shown = {};
    _listings = {};
    _workspace = location is ProjectLocation
        ? LspWorkspace.project(location.folder)
        : null;
    _service = service;
    _clock = clock;
    _settings = settings;
    final available = service.available && enabled;
    final offReason = !runtimeReady
        ? 'The Linux runtime is not ready'
        : _workspace == null
        ? 'Not yet for folders from shared storage'
        : null;
    _enabled = available && offReason == null;
    ref.onDispose(() {
      // Whatever this build scheduled finds itself stale.
      _build += 1;
      _enabled = false;
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      for (final client in clients.values) {
        unawaited(client.dispose());
      }
    });
    if (_enabled) {
      final edits = host.events.listen(_onEditorEvent);
      ref.onDispose(() => unawaited(edits.cancel()));
      ref.listen<DocumentsState>(documentControllerProvider, _onDocuments);
      final build = _build;
      scheduleMicrotask(() {
        if (build == _build) {
          _onDocuments(null, ref.read(documentControllerProvider));
        }
      });
    }
    return LspState(available: available, offReason: offReason);
  }

  late LspService _service;
  late LspClock _clock;
  late LspClientSettings _settings;

  /// [server]'s client, while it has one (W5's features ask through it).
  LanguageClient? clientFor(LspServerId server) => _clients[server];

  /// The user's *Restart* on the chip.
  Future<void> restart(LspServerId server) async {
    await _clients[server]?.restart();
  }

  /// Phase 3's watcher listed [folder] again (file_watch_controller.dart):
  /// what changed since its last listing goes to the servers. A folder's
  /// first listing is only remembered.
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
    if (changes.isEmpty) {
      return;
    }
    for (final client in _clients.values) {
      client.filesChanged(changes);
    }
  }

  /// Phase 3's watcher found [folder] gone.
  void folderGone(String folder) {
    final before = _listings.remove(folder);
    _listings.removeWhere((key, _) => key.startsWith('$folder/'));
    if (!_enabled || before == null || folder.isEmpty) {
      return;
    }
    final changes = [LspFileChange(folder, LspFileChangeType.deleted)];
    for (final client in _clients.values) {
      client.filesChanged(changes);
    }
  }

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
      final server = doc == null || doc.largeFile
          ? null
          : LspServerId.forLanguage(doc.language);
      if (doc == null || server != shown.server || doc.path != shown.path) {
        _shown.remove(docId);
        _clients[shown.server]?.close(shown.path);
      }
    }
    // Saved: its stamp moved while it is not dirty.
    if (previous != null) {
      for (final MapEntry(key: docId, value: shown) in _shown.entries) {
        final doc = byDocId[docId];
        final before = previous.documents[shown.path];
        if (doc != null &&
            before != null &&
            before.docId == docId &&
            before.stamp != doc.stamp &&
            !doc.dirty) {
          _clients[shown.server]?.saved(shown.path);
        }
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

  void _show(OpenDocument doc) {
    final server = doc.largeFile ? null : LspServerId.forLanguage(doc.language);
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
    client.open(
      doc.path,
      language: doc.language,
      version: version,
      text: text,
    );
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
