/// One language server's client (Phase 6 W4; PHASE_6_PLAN W4,
/// docs/LSP_ARCHITECTURE.md §1): the session, the documents, the restarts.
///
/// - **The session:** the server starts when a document of its languages is
///   first shown. `initialize` offers UTF-16 positions only, which Dart and
///   CodeMirror count in too, and one workspace folder: the root the host
///   names (a project's folder, or a folder's copy). The server's own
///   requests are answered: its settings from a fixed table
///   (`workspace/configuration`), its registrations, its progress tokens.
///   Its log lines go to the app's log, at most so many a minute.
/// - **Documents:** `didOpen` with the whole text; then each of the editor's
///   change sets as incremental ranges (core/lsp/text_sync.dart), applied in
///   order with strictly growing versions; the whole text only after a
///   resync, or when an edit does not follow what the client holds.
///   `didSave`, `didClose`, and files changed outside the app as
///   `didChangeWatchedFiles`, to the servers that asked for them. A request
///   about a document waits until every edit up to the version the page
///   names has gone out, so the server answers about the text on screen.
/// - **Restarts:** a server that exits, crashes or breaks the protocol starts
///   again after 1 s, 2 s, then 4 s, at most three times in five minutes;
///   after that the client gives up, and the status offers *Restart*.
///   Requests in flight fail as restarting, and every open document is
///   opened again in the new server.
/// - **The idle stop:** a server with no open document for ten minutes is
///   asked to shut down and exit, and stopped through the host if it does
///   not.
/// - **Status:** off, starting, ready, analysing (while the server reports
///   progress) or restarting, with the reason (the status strip's chip).
library;

import 'dart:async';

import '../../core/editor/change_set.dart';
import '../../core/errors/failure.dart';
import '../../core/logging/logger.dart';
import '../../core/lsp/lsp_glob.dart';
import '../../core/lsp/lsp_models.dart';
import '../../core/lsp/lsp_uri.dart';
import '../../core/lsp/text_sync.dart';
import '../../core/version.dart';
import '../../services/contracts.dart';
import 'lsp_clock.dart';
import 'lsp_connection.dart';

/// How a client paces itself (PHASE_6_PLAN W4).
final class LspClientSettings {
  const LspClientSettings({
    this.completionTimeout = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 10),
    this.restartDelays = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.restartWindow = const Duration(minutes: 5),
    this.idleStop = const Duration(minutes: 10),
    this.shutdownGrace = const Duration(seconds: 2),
    this.timingsKept = 500,
    this.logLinesPerMinute = 20,
  });

  /// How long a completion may take before it is given up.
  final Duration completionTimeout;

  /// How long any other request may take, `initialize` included.
  final Duration requestTimeout;

  /// The pause before each restart in a row; as many restarts as entries
  /// within [restartWindow], then the client gives up.
  final List<Duration> restartDelays;
  final Duration restartWindow;

  /// How long a server runs with no open document before it is stopped.
  final Duration idleStop;

  /// How long `shutdown` may take, and then how long the process may take
  /// to exit before the host stops it.
  final Duration shutdownGrace;

  /// How many requests' timings are kept (the newest).
  final int timingsKept;

  /// How many of the server's log lines reach the app's log each minute.
  final int logLinesPerMinute;
}

final class LanguageClient {
  LanguageClient({
    required this.server,
    required this.workspace,
    required LspService service,
    LspClock clock = const SystemLspClock(),
    this.settings = const LspClientSettings(),
  }) : _service = service,
       _clock = clock {
    _messages = _service.messages.listen(_onMessage);
    _exits = _service.exits.listen(_onExit);
  }

  final LspServerId server;
  final LspWorkspace workspace;
  final LspClientSettings settings;
  final LspService _service;
  final LspClock _clock;
  late final StreamSubscription<LspIncoming> _messages;
  late final StreamSubscription<LspExit> _exits;

  final StreamController<LspStatus> _statusChanges =
      StreamController<LspStatus>.broadcast();
  final StreamController<LspDiagnostics> _diagnosticsChanges =
      StreamController<LspDiagnostics>.broadcast();
  LspStatus _status = LspStatus.off;

  /// The running server: its handle, where it works, the connection.
  int? _handle;
  LspStarted? _started;
  LspRoot? _root;
  LspConnection? _connection;

  /// The handshake is done: documents go to the server.
  bool _initialized = false;
  Map<String, Object?> _capabilities = const {};

  final Map<String, _Document> _documents = {};
  final Map<String, LspDiagnostics> _diagnostics = {};
  final Map<String, List<_Watcher>> _watchers = {};
  final Set<Object> _progress = {};

  /// When each restart in the window was scheduled (nowMs).
  final List<int> _restarts = [];
  final List<LspTiming> _timings = [];

  /// Handles whose exit is no news: servers this client ended itself.
  final Set<int> _ignoredExits = {};

  /// Stops waiting for their server's exit.
  final Map<int, Completer<void>> _exitWaiters = {};
  Timer? _restartTimer;
  Timer? _idleTimer;

  /// Grows with every start and stop: what an older one awaited is stale.
  int _generation = 0;

  /// Only the user's *Restart* starts it again.
  bool _gaveUp = false;
  bool _disposed = false;

  int _logWindowStartMs = 0;
  int _logLines = 0;
  int _logDropped = 0;

  /// Diagnostics the server published for files outside the workspace.
  int diagnosticsOutside = 0;

  LspStatus get status => _status;

  Stream<LspStatus> get statusChanges => _statusChanges.stream;

  /// Each document's diagnostics, as its server publishes them (an empty
  /// list clears them).
  Stream<LspDiagnostics> get diagnosticsChanges => _diagnosticsChanges.stream;

  Map<String, LspDiagnostics> get diagnostics => Map.unmodifiable(_diagnostics);

  /// The newest requests' timings, oldest first.
  List<LspTiming> get timings => List.unmodifiable(_timings);

  /// The documents shown to the server, by workspace path.
  Iterable<String> get openPaths => _documents.keys;

  /// The server's handle while it runs.
  int? get handle => _handle;

  /// What the server said it can do.
  Map<String, Object?> get capabilities => _capabilities;

  /// The URI of workspace path [path], once the server has started.
  String? uriOf(String path) => _root?.uriOf(path);

  /// The workspace path [uri] names, or null (outside the workspace, or no
  /// server yet).
  String? pathOf(String uri) => _root?.relativeOf(uri);

  /// The version of [path] the server holds (LSP's, strictly growing).
  int? versionOf(String path) => _documents[path]?.version;

  // -------------------------------------------------------------- documents

  /// Shows [path] to the server: `didOpen` with its whole [text] at the
  /// editor's [version], now or once the server is ready. The server starts
  /// if it is not running.
  void open(
    String path, {
    required String language,
    required int version,
    required String text,
  }) {
    if (_disposed) {
      return;
    }
    final known = _documents[path];
    if (known != null) {
      if (version > known.editorVersion) {
        replaceText(path, version: version, text: text);
      }
      _ensureStarted();
      return;
    }
    final doc = _Document(
      path: path,
      languageId: lspLanguageIds[language] ?? language,
      text: text,
      editorVersion: version,
    );
    _documents[path] = doc;
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_initialized) {
      _sendOpen(doc);
    } else {
      _ensureStarted();
    }
  }

  /// The editor's edit of [path] from [baseVersion] to [version]
  /// (EditorHost's DocumentEdited), sent as incremental changes. False when
  /// it does not follow the text the client holds (it missed one): the
  /// caller then sends the editor's whole text ([replaceText]).
  bool applyEdit(
    String path, {
    required int baseVersion,
    required int version,
    required List<Object?> changes,
  }) {
    final doc = _documents[path];
    if (doc == null || version <= doc.editorVersion) {
      // Not shown here, or overtaken by a whole text that has it already.
      return true;
    }
    if (baseVersion != doc.editorVersion) {
      return false;
    }
    final List<Map<String, Object?>> contentChanges;
    final String after;
    try {
      contentChanges = contentChangesFor(doc.text, changes);
      after = applyChanges(doc.text, changes);
    } on ChangeApplyException {
      return false;
    }
    doc.text = after;
    _advance(doc, version);
    if (doc.opened && _initialized && contentChanges.isNotEmpty) {
      _sendChange(doc, contentChanges);
    }
    return true;
  }

  /// [path]'s whole [text] at the editor's [version]: a resync, a reload
  /// from disk, or an edit the client could not follow. Sent whole.
  void replaceText(String path, {required int version, required String text}) {
    final doc = _documents[path];
    if (doc == null || version < doc.editorVersion) {
      return;
    }
    if (version == doc.editorVersion && text == doc.text) {
      return;
    }
    doc.text = text;
    _advance(doc, version);
    if (doc.opened && _initialized) {
      _sendChange(doc, [
        <String, Object?>{'text': text},
      ]);
    }
  }

  /// [path] was saved: `didSave`, to a server that asked for it.
  void saved(String path) {
    final doc = _documents[path];
    final connection = _connection;
    final root = _root;
    final save = _saveOptions();
    if (doc == null ||
        !doc.opened ||
        !_initialized ||
        connection == null ||
        root == null ||
        save == null) {
      return;
    }
    connection.notify('textDocument/didSave', <String, Object?>{
      'textDocument': <String, Object?>{'uri': root.uriOf(path)},
      if (save.includeText) 'text': doc.text,
    });
  }

  /// [path]'s tab closed: `didClose`, and its diagnostics go. The last one
  /// to close starts the idle stop's countdown.
  void close(String path) {
    final doc = _documents.remove(path);
    if (doc == null) {
      return;
    }
    _failWaiters(doc);
    final connection = _connection;
    final root = _root;
    if (doc.opened && _initialized && connection != null && root != null) {
      connection.notify('textDocument/didClose', <String, Object?>{
        'textDocument': <String, Object?>{'uri': root.uriOf(path)},
      });
    }
    _dropDiagnostics(path);
    if (_documents.isEmpty && _handle != null) {
      _armIdleStop();
    }
  }

  /// Files changed in the workspace (Phase 3's watcher): those a server
  /// registered for go to it as `didChangeWatchedFiles`.
  void filesChanged(List<LspFileChange> changes) {
    final connection = _connection;
    final root = _root;
    if (!_initialized ||
        connection == null ||
        root == null ||
        _watchers.isEmpty ||
        changes.isEmpty) {
      return;
    }
    final wanted = <Map<String, Object?>>[
      for (final change in changes)
        if (_watches(root, change))
          <String, Object?>{
            'uri': root.uriOf(change.path),
            'type': change.type.value,
          },
    ];
    if (wanted.isEmpty) {
      return;
    }
    connection.notify('workspace/didChangeWatchedFiles', <String, Object?>{
      'changes': wanted,
    });
  }

  // --------------------------------------------------------------- requests

  /// Asks the server [method] with [params]. With [path] and [atVersion],
  /// the request waits until every edit up to the editor's [atVersion] of
  /// [path] has gone out. Fails as [LspProblem.restarting] while the server
  /// starts or restarts, and [LspProblem.stopped] while it is off; [cancel]
  /// calls it off. A completion may take [LspClientSettings.completionTimeout],
  /// anything else [LspClientSettings.requestTimeout], unless [timeout] says.
  Future<Result<Object?>> request(
    String method,
    Object? params, {
    String? path,
    int? atVersion,
    LspCancel? cancel,
    Duration? timeout,
  }) async {
    final limit =
        timeout ??
        (method == 'textDocument/completion'
            ? settings.completionTimeout
            : settings.requestTimeout);
    if (path != null && atVersion != null) {
      final doc = _documents[path];
      if (doc == null) {
        return Err<Object?>(
          LspFailure(
            '$path is not open in ${server.title}.',
            problem: LspProblem.badRequest,
          ),
        );
      }
      if (doc.editorVersion < atVersion &&
          !await _waitForVersion(doc, atVersion, limit)) {
        return Err<Object?>(
          LspFailure(
            '$path did not reach version $atVersion in time.',
            problem: LspProblem.timeout,
          ),
        );
      }
    }
    final connection = _connection;
    if (connection == null || !_initialized) {
      final starting =
          _status.phase == LspPhase.starting ||
          _status.phase == LspPhase.restarting;
      return Err<Object?>(
        LspFailure(
          '${server.title} is ${_status.phase.label}.',
          problem: starting ? LspProblem.restarting : LspProblem.stopped,
        ),
      );
    }
    return connection.request(method, params, timeout: limit, cancel: cancel);
  }

  // -------------------------------------------------------------- lifecycle

  /// The user's *Restart*: earlier crashes are forgotten, the server (if it
  /// runs) is stopped, and a new one starts with every open document.
  Future<void> restart() async {
    if (_disposed) {
      return;
    }
    _restarts.clear();
    _gaveUp = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _generation += 1;
    final handle = _handle;
    if (handle != null) {
      _ignoredExits.add(handle);
      _detach(LspProblem.restarting, '${server.title} is restarting.');
      await _service.stop(handle);
    }
    _setStatus(LspStatus.off);
    await _start();
  }

  /// Ends the server: `shutdown`, then `exit`, then the host's stop if it
  /// has not ended within [LspClientSettings.shutdownGrace]. The documents
  /// stay known: a later [open] starts it again with all of them.
  Future<void> stop({String? reason}) async {
    _restartTimer?.cancel();
    _restartTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _generation += 1;
    final handle = _handle;
    final connection = _connection;
    final initialized = _initialized;
    _setStatus(LspStatus(LspPhase.off, reason: reason));
    if (handle == null) {
      return;
    }
    final ended = Completer<void>();
    _exitWaiters[handle] = ended;
    if (connection != null && initialized) {
      await connection.request(
        'shutdown',
        null,
        timeout: settings.shutdownGrace,
      );
      connection.notify('exit', null);
    }
    _detach(LspProblem.stopped, '${server.title} stopped.');
    final backstop = _clock.timer(settings.shutdownGrace, () {
      if (!ended.isCompleted) {
        unawaited(_service.stop(handle));
      }
    });
    final giveUp = _clock.timer(settings.shutdownGrace * 2, () {
      if (!ended.isCompleted) {
        ended.complete();
      }
    });
    await ended.future;
    backstop.cancel();
    giveUp.cancel();
    _exitWaiters.remove(handle);
  }

  /// Ends the client: the server stopped through the host (the app or the
  /// workspace is going, so without the handshake), the streams closed.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation += 1;
    _restartTimer?.cancel();
    _idleTimer?.cancel();
    for (final doc in _documents.values) {
      _failWaiters(doc);
    }
    final handle = _handle;
    _detach(LspProblem.stopped, '${server.title} stopped.');
    if (handle != null) {
      _ignoredExits.add(handle);
      unawaited(_service.stop(handle));
    }
    for (final waiter in _exitWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    await _messages.cancel();
    await _exits.cancel();
    await _statusChanges.close();
    await _diagnosticsChanges.close();
  }

  void _ensureStarted() {
    if (_disposed || _gaveUp || _status.phase != LspPhase.off) {
      return;
    }
    unawaited(_start());
  }

  Future<void> _start() async {
    _generation += 1;
    final generation = _generation;
    _restartTimer?.cancel();
    _restartTimer = null;
    if (_status.phase != LspPhase.restarting) {
      _setStatus(const LspStatus(LspPhase.starting));
    }
    final started = await _service.start(server, workspace);
    if (generation != _generation || _disposed) {
      // Stopped meanwhile: no one wants this server.
      if (started case Ok<LspStarted>(:final value)) {
        _ignoredExits.add(value.handle);
        unawaited(_service.stop(value.handle));
      }
      return;
    }
    switch (started) {
      case Err<LspStarted>(:final failure):
        _startFailed(failure);
      case Ok<LspStarted>(:final value):
        _attach(value, generation);
    }
  }

  void _startFailed(Failure failure) {
    final problem = failure is LspFailure
        ? failure.problem
        : LspProblem.unknown;
    appLogger.warn(
      'lsp',
      'start_failed',
      fields: {'server': server.id, 'problem': problem.code},
    );
    switch (problem) {
      case LspProblem.alreadyRunning:
        // One was left running (a Dart restart): stop it, and try again.
        final running = failure is LspFailure ? failure.running : null;
        if (running != null) {
          _ignoredExits.add(running);
          unawaited(_service.stop(running));
        }
        _crashed('An earlier ${server.title} was still running');
      case LspProblem.notReady:
        _setStatus(
          const LspStatus(
            LspPhase.off,
            reason: 'The Linux runtime is not ready',
          ),
        );
      case LspProblem.launchFailed || LspProblem.timeout || LspProblem.unknown:
        _crashed(failure.message);
      default:
        // It cannot succeed by itself: no host, damaged, no room, refused.
        _gaveUp = true;
        _setStatus(
          LspStatus(
            LspPhase.off,
            reason: failure.message,
            canRestart: problem != LspProblem.unavailable,
          ),
        );
    }
  }

  void _attach(LspStarted started, int generation) {
    _handle = started.handle;
    _started = started;
    _root = LspRoot(started.root);
    _initialized = false;
    _progress.clear();
    _watchers.clear();
    final connection = LspConnection(
      server: server,
      send: (json) => _service.send(started.handle, json),
      clock: _clock,
      onRequest: _answer,
      onNotification: _notified,
      onTiming: _record,
    );
    _connection = connection;
    unawaited(_initialize(connection, generation));
  }

  Future<void> _initialize(LspConnection connection, int generation) async {
    final answer = await connection.request(
      'initialize',
      _initializeParams(),
      timeout: settings.requestTimeout,
    );
    if (generation != _generation || _disposed || connection.isClosed) {
      return;
    }
    switch (answer) {
      case Err<Object?>(:final failure):
        appLogger.warn(
          'lsp',
          'initialize_failed',
          fields: {
            'server': server.id,
            'problem': failure is LspFailure ? failure.problem.code : 'unknown',
          },
        );
        _abandonServer('${server.title} did not start: ${failure.message}');
        return;
      case Ok<Object?>(:final value):
        final capabilities = value is Map<String, Object?>
            ? value['capabilities']
            : null;
        _capabilities = capabilities is Map<String, Object?>
            ? capabilities
            : const {};
    }
    connection.notify('initialized', <String, Object?>{});
    _initialized = true;
    _setStatus(
      LspStatus(_progress.isEmpty ? LspPhase.ready : LspPhase.analysing),
    );
    for (final doc in _documents.values) {
      _sendOpen(doc);
    }
    if (_documents.isEmpty) {
      _armIdleStop();
    }
    appLogger.info(
      'lsp',
      'ready',
      fields: {'server': server.id, 'documents': _documents.length},
    );
  }

  /// A server that cannot shake hands is ended, and counts as a crash.
  void _abandonServer(String reason) {
    final handle = _handle;
    _detach(LspProblem.restarting, reason);
    if (handle != null) {
      _ignoredExits.add(handle);
      unawaited(_service.stop(handle));
    }
    _crashed(reason);
  }

  /// Forgets the running server: its requests fail as [problem], its
  /// documents and diagnostics wait for the next one.
  void _detach(LspProblem problem, String message) {
    _connection?.close(problem, message);
    _connection = null;
    _handle = null;
    _initialized = false;
    _progress.clear();
    _watchers.clear();
    for (final doc in _documents.values) {
      doc.opened = false;
    }
    for (final path in _diagnostics.keys.toList()) {
      _dropDiagnostics(path);
    }
  }

  void _crashed(String reason) {
    final now = _clock.nowMs;
    _restarts.removeWhere(
      (at) => now - at >= settings.restartWindow.inMilliseconds,
    );
    if (_restarts.length >= settings.restartDelays.length) {
      _gaveUp = true;
      _setStatus(
        LspStatus(
          LspPhase.off,
          reason:
              '$reason. It ended ${_restarts.length + 1} times in '
              '${settings.restartWindow.inMinutes} minutes',
          canRestart: true,
        ),
      );
      appLogger.error(
        'lsp',
        'gave_up',
        fields: {'server': server.id, 'restarts': _restarts.length},
      );
      return;
    }
    final delay = settings.restartDelays[_restarts.length];
    _restarts.add(now);
    _setStatus(LspStatus(LspPhase.restarting, reason: reason));
    appLogger.info(
      'lsp',
      'restart_scheduled',
      fields: {
        'server': server.id,
        'attempt': _restarts.length,
        'delayMs': delay.inMilliseconds,
      },
    );
    _restartTimer?.cancel();
    _restartTimer = _clock.timer(delay, () {
      _restartTimer = null;
      if (!_disposed) {
        unawaited(_start());
      }
    });
  }

  void _armIdleStop() {
    _idleTimer?.cancel();
    _idleTimer = _clock.timer(settings.idleStop, () {
      _idleTimer = null;
      if (_documents.isEmpty && _handle != null) {
        appLogger.info('lsp', 'idle_stop', fields: {'server': server.id});
        unawaited(
          stop(
            reason:
                'Stopped after ${settings.idleStop.inMinutes} minutes '
                'without an open file',
          ),
        );
      }
    });
  }

  // ------------------------------------------------------------ the server

  void _onMessage(LspIncoming incoming) {
    if (incoming.handle != _handle) {
      return;
    }
    _connection?.receive(incoming.json, readUs: incoming.readUs);
  }

  void _onExit(LspExit exit) {
    // Every client hears every server's exit: only its own running one's
    // is news, and one it asked for or ended itself is not a crash.
    final waiter = _exitWaiters.remove(exit.handle);
    final current = exit.handle == _handle;
    if (current) {
      final aside =
          waiter != null ||
          exit.end == LspEnd.memory ||
          exit.end == LspEnd.stopped;
      _detach(
        aside ? LspProblem.stopped : LspProblem.restarting,
        _describe(exit),
      );
    }
    if (waiter != null) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
      return;
    }
    final ignored = _ignoredExits.remove(exit.handle);
    if (!current || ignored || _disposed) {
      return;
    }
    appLogger.warn(
      'lsp',
      'server_ended',
      fields: {
        'server': server.id,
        'end': exit.end.code,
        'exitCode': exit.exitCode,
        'signal': exit.signal,
        'stderrBytes': exit.stderr.length,
      },
    );
    switch (exit.end) {
      case LspEnd.memory:
        _setStatus(
          const LspStatus(
            LspPhase.off,
            reason:
                'Stopped to free memory; it starts again with the next '
                'file shown',
          ),
        );
      case LspEnd.stopped:
        _setStatus(
          LspStatus(
            LspPhase.off,
            reason: exit.detail ?? '${server.title} was stopped',
            canRestart: true,
          ),
        );
      case LspEnd.exited || LspEnd.signaled || LspEnd.broken || LspEnd.lost:
        _crashed(_describe(exit));
    }
  }

  String _describe(LspExit exit) => switch (exit.end) {
    LspEnd.exited => '${server.title} exited (code ${exit.exitCode})',
    LspEnd.signaled => '${server.title} was ended by signal ${exit.signal}',
    LspEnd.broken =>
      '${server.title} wrote something that is not the language server '
          'protocol',
    LspEnd.lost => '${server.title} was lost',
    LspEnd.memory => '${server.title} was stopped to free memory',
    LspEnd.stopped => '${server.title} was stopped',
  };

  Future<LspReply> _answer(String method, Object? params) async {
    switch (method) {
      case 'workspace/configuration':
        final items = params is Map<String, Object?> ? params['items'] : null;
        return LspReply.result(<Object?>[
          if (items is List<Object?>)
            for (final item in items)
              _configuration(
                item is Map<String, Object?> ? item['section'] : null,
              ),
        ]);
      case 'client/registerCapability':
        _register(params);
        return const LspReply.result(null);
      case 'client/unregisterCapability':
        _unregister(params);
        return const LspReply.result(null);
      case 'window/workDoneProgress/create':
        return const LspReply.result(null);
      case 'workspace/workspaceFolders':
        final root = _root;
        return LspReply.result(
          root == null
              ? null
              : <Object?>[
                  <String, Object?>{'uri': root.uri, 'name': workspace.name},
                ],
        );
      case 'window/showMessageRequest':
        _logServer(params);
        return const LspReply.result(null);
      case 'window/showDocument':
        return const LspReply.result(<String, Object?>{'success': false});
      case 'workspace/applyEdit':
        return const LspReply.result(<String, Object?>{
          'applied': false,
          'failureReason': 'CodeForge applies no edit a server asks for.',
        });
      case 'workspace/semanticTokens/refresh' ||
          'workspace/inlayHint/refresh' ||
          'workspace/inlineValue/refresh' ||
          'workspace/codeLens/refresh' ||
          'workspace/diagnostic/refresh' ||
          'workspace/foldingRange/refresh':
        return const LspReply.result(null);
      default:
        return LspReply.error(
          JsonRpcErrors.methodNotFound,
          'CodeForge does not handle $method.',
        );
    }
  }

  void _notified(String method, Object? params) {
    switch (method) {
      case 'textDocument/publishDiagnostics':
        _published(params);
      case r'$/progress':
        _progressed(params);
      case 'window/logMessage' || 'window/showMessage':
        _logServer(params);
      case 'telemetry/event' || r'$/logTrace' || r'$/cancelRequest':
        break;
      default:
        appLogger.debug(
          'lsp',
          'notification_ignored',
          fields: {'server': server.id, 'method': method},
        );
    }
  }

  /// The settings a server asks for, from a fixed table: nothing the user
  /// typed, and no path but those the host gave (PHASE_6_PLAN W4: sanitized).
  Object? _configuration(Object? section) {
    switch (server) {
      case LspServerId.pyright:
        final bin = _started?.bin;
        return switch (section) {
          'python' => <String, Object?>{
            if (bin != null) 'pythonPath': '$bin/python',
          },
          'python.analysis' => const <String, Object?>{
            'diagnosticMode': 'openFilesOnly',
            'autoSearchPaths': true,
            'useLibraryCodeForTypes': true,
          },
          'pyright' => const <String, Object?>{},
          _ => null,
        };
      case LspServerId.typescript:
        return null;
    }
  }

  Map<String, Object?> _initializeParams() {
    final root = _root!;
    return <String, Object?>{
      'processId': null,
      'clientInfo': <String, Object?>{
        'name': 'CodeForge',
        'version': appVersion,
      },
      'locale': 'en',
      'rootPath': root.path,
      'rootUri': root.uri,
      'workspaceFolders': <Object?>[
        <String, Object?>{'uri': root.uri, 'name': workspace.name},
      ],
      'initializationOptions': _initializationOptions(),
      'capabilities': clientCapabilities,
      'trace': 'off',
    };
  }

  /// Each server's options (ADR-0015): typescript-language-server runs the
  /// APK's TypeScript, one tsserver, and fetches no typings from the
  /// network; Pyright takes its settings through `workspace/configuration`.
  Map<String, Object?> _initializationOptions() {
    switch (server) {
      case LspServerId.pyright:
        return const <String, Object?>{};
      case LspServerId.typescript:
        final directory = _started?.serverDirectory;
        return <String, Object?>{
          'tsserver': <String, Object?>{
            if (directory != null)
              'path': '$directory/node_modules/typescript/lib/tsserver.js',
            'useSyntaxServer': 'never',
          },
          'disableAutomaticTypingAcquisition': true,
        };
    }
  }

  void _register(Object? params) {
    final registrations = params is Map<String, Object?>
        ? params['registrations']
        : null;
    if (registrations is! List<Object?>) {
      return;
    }
    for (final registration in registrations) {
      if (registration is! Map<String, Object?>) {
        continue;
      }
      final id = registration['id'];
      final method = registration['method'];
      final options = registration['registerOptions'];
      if (id is! String || method != 'workspace/didChangeWatchedFiles') {
        continue;
      }
      final watchers = options is Map<String, Object?>
          ? options['watchers']
          : null;
      _watchers[id] = [
        if (watchers is List<Object?>)
          for (final watcher in watchers) ?_Watcher.fromJson(watcher),
      ];
    }
  }

  void _unregister(Object? params) {
    // LSP spells it "unregisterations".
    final removals = params is Map<String, Object?>
        ? params['unregisterations']
        : null;
    if (removals is! List<Object?>) {
      return;
    }
    for (final removal in removals) {
      if (removal is Map<String, Object?>) {
        final id = removal['id'];
        if (id is String) {
          _watchers.remove(id);
        }
      }
    }
  }

  bool _watches(LspRoot root, LspFileChange change) {
    final absolute = change.path.isEmpty
        ? root.path
        : '${root.path}/${change.path}';
    final bit = switch (change.type) {
      LspFileChangeType.created => 1,
      LspFileChangeType.changed => 2,
      LspFileChangeType.deleted => 4,
    };
    for (final watchers in _watchers.values) {
      for (final watcher in watchers) {
        if (watcher.kinds & bit != 0 &&
            watcher.matches(absolute, change.path)) {
          return true;
        }
      }
    }
    return false;
  }

  /// `textDocumentSync.save`, when the server wants `didSave`.
  ({bool includeText})? _saveOptions() {
    final sync = _capabilities['textDocumentSync'];
    if (sync is! Map<String, Object?>) {
      return null;
    }
    final save = sync['save'];
    if (save == true) {
      return (includeText: false);
    }
    if (save is Map<String, Object?>) {
      return (includeText: save['includeText'] == true);
    }
    return null;
  }

  /// The server's TextDocumentSyncKind: 0 none, 1 whole texts, 2 ranges.
  int get _syncKind {
    final sync = _capabilities['textDocumentSync'];
    if (sync is int) {
      return sync;
    }
    if (sync is Map<String, Object?>) {
      final change = sync['change'];
      if (change is int) {
        return change;
      }
      return 0;
    }
    return 2;
  }

  void _sendOpen(_Document doc) {
    final connection = _connection;
    final root = _root;
    if (connection == null || root == null || !_initialized) {
      return;
    }
    doc.opened = true;
    connection.notify('textDocument/didOpen', <String, Object?>{
      'textDocument': <String, Object?>{
        'uri': root.uriOf(doc.path),
        'languageId': doc.languageId,
        'version': doc.version,
        'text': doc.text,
      },
    });
  }

  void _sendChange(_Document doc, List<Map<String, Object?>> changes) {
    final connection = _connection;
    final root = _root;
    final kind = _syncKind;
    if (connection == null || root == null || kind == 0) {
      return;
    }
    connection.notify('textDocument/didChange', <String, Object?>{
      'textDocument': <String, Object?>{
        'uri': root.uriOf(doc.path),
        'version': doc.version,
      },
      'contentChanges': kind == 1
          ? <Object?>[
              <String, Object?>{'text': doc.text},
            ]
          : changes,
    });
  }

  /// The editor's [editorVersion] reached: LSP's version grows by at least
  /// one, and follows the editor's where it can.
  void _advance(_Document doc, int editorVersion) {
    doc
      ..editorVersion = editorVersion
      ..version = editorVersion > doc.version ? editorVersion : doc.version + 1;
    doc.waiters.removeWhere((waiter) {
      if (waiter.version > editorVersion) {
        return false;
      }
      waiter.timer?.cancel();
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(true);
      }
      return true;
    });
  }

  Future<bool> _waitForVersion(_Document doc, int version, Duration limit) {
    final waiter = _VersionWaiter(version);
    waiter.timer = _clock.timer(limit, () {
      doc.waiters.remove(waiter);
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(false);
      }
    });
    doc.waiters.add(waiter);
    return waiter.completer.future;
  }

  void _failWaiters(_Document doc) {
    for (final waiter in doc.waiters) {
      waiter.timer?.cancel();
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(false);
      }
    }
    doc.waiters.clear();
  }

  void _published(Object? params) {
    final root = _root;
    if (params is! Map<String, Object?> || root == null) {
      return;
    }
    final uri = params['uri'];
    final list = params['diagnostics'];
    if (uri is! String || list is! List<Object?>) {
      return;
    }
    final path = root.relativeOf(uri);
    if (path == null) {
      diagnosticsOutside += 1;
      return;
    }
    final version = params['version'];
    final published = LspDiagnostics(
      server: server,
      path: path,
      version: version is int ? version : null,
      items: list
          .map(LspDiagnostic.fromJson)
          .whereType<LspDiagnostic>()
          .toList(growable: false),
    );
    if (published.items.isEmpty) {
      _diagnostics.remove(path);
    } else {
      _diagnostics[path] = published;
    }
    if (!_diagnosticsChanges.isClosed) {
      _diagnosticsChanges.add(published);
    }
  }

  void _dropDiagnostics(String path) {
    if (_diagnostics.remove(path) == null) {
      return;
    }
    if (!_diagnosticsChanges.isClosed) {
      _diagnosticsChanges.add(
        LspDiagnostics(server: server, path: path, items: const []),
      );
    }
  }

  void _progressed(Object? params) {
    if (params is! Map<String, Object?>) {
      return;
    }
    final token = params['token'];
    final value = params['value'];
    if (token == null || value is! Map<String, Object?>) {
      return;
    }
    switch (value['kind']) {
      case 'begin':
        _progress.add(token);
      case 'end':
        _progress.remove(token);
      default:
        return;
    }
    if (_initialized) {
      _setStatus(
        LspStatus(_progress.isEmpty ? LspPhase.ready : LspPhase.analysing),
      );
    }
  }

  /// One of the server's log lines into the app's log, at most
  /// [LspClientSettings.logLinesPerMinute] a minute.
  void _logServer(Object? params) {
    if (params is! Map<String, Object?>) {
      return;
    }
    final now = _clock.nowMs;
    if (now - _logWindowStartMs >= 60000) {
      if (_logDropped > 0) {
        appLogger.info(
          'lsp',
          'server_log_dropped',
          fields: {'server': server.id, 'lines': _logDropped},
        );
      }
      _logWindowStartMs = now;
      _logLines = 0;
      _logDropped = 0;
    }
    if (_logLines >= settings.logLinesPerMinute) {
      _logDropped += 1;
      return;
    }
    _logLines += 1;
    final message = params['message'];
    final fields = <String, Object?>{
      'server': server.id,
      'message': message is String ? _clip(message) : '',
    };
    switch (params['type']) {
      case 1:
        appLogger.warn('lsp', 'server_error', fields: fields);
      case 2:
        appLogger.info('lsp', 'server_warning', fields: fields);
      default:
        appLogger.debug('lsp', 'server_log', fields: fields);
    }
  }

  void _record(LspTiming timing) {
    _timings.add(timing);
    if (_timings.length > settings.timingsKept) {
      _timings.removeAt(0);
    }
    final budgetUs = timing.method == 'textDocument/completion'
        ? 300000
        : 1000000;
    if (timing.outcome == 'ok' && timing.totalUs > budgetUs) {
      appLogger.info(
        'lsp',
        'slow_request',
        fields: {
          'server': server.id,
          'method': timing.method,
          'totalUs': timing.totalUs,
          'queueUs': timing.queueUs,
          'serverUs': timing.serverUs,
          'deliveryUs': timing.deliveryUs,
        },
      );
    }
  }

  void _setStatus(LspStatus status) {
    if (status == _status) {
      return;
    }
    _status = status;
    if (!_statusChanges.isClosed) {
      _statusChanges.add(status);
    }
  }

  static String _clip(String text) =>
      text.length <= 300 ? text : '${text.substring(0, 300)}…';
}

/// What the client offers every server (`initialize`'s capabilities): UTF-16
/// positions only, incremental sync with `didSave`, the server's settings
/// asked for, file watchers registered, progress, and the requests W5 makes.
const Map<String, Object?> clientCapabilities = {
  'general': {
    'positionEncodings': ['utf-16'],
  },
  'workspace': {
    'configuration': true,
    'workspaceFolders': true,
    'didChangeWatchedFiles': {
      'dynamicRegistration': true,
      'relativePatternSupport': true,
    },
    'workspaceEdit': {'documentChanges': true},
  },
  'textDocument': {
    'synchronization': {
      'dynamicRegistration': false,
      'didSave': true,
      'willSave': false,
      'willSaveWaitUntil': false,
    },
    'completion': {
      'contextSupport': true,
      'completionItem': {
        'snippetSupport': false,
        'documentationFormat': ['markdown', 'plaintext'],
        'labelDetailsSupport': true,
        'resolveSupport': {
          'properties': ['documentation', 'detail'],
        },
      },
    },
    'hover': {
      'contentFormat': ['markdown', 'plaintext'],
    },
    'definition': {'linkSupport': false},
    'rename': {'prepareSupport': true},
    'publishDiagnostics': {
      'relatedInformation': false,
      'versionSupport': true,
      'tagSupport': {
        'valueSet': [1, 2],
      },
    },
  },
  'window': {'workDoneProgress': true},
};

/// A document the server is shown: the text the client holds (the editor's
/// at [editorVersion]) and the version the server knows it by.
final class _Document {
  _Document({
    required this.path,
    required this.languageId,
    required this.text,
    required this.editorVersion,
  }) : version = editorVersion;

  final String path;
  final String languageId;
  String text;
  int editorVersion;

  /// LSP's version: strictly growing, the editor's where it can be.
  int version;

  /// `didOpen` went to the server that runs now.
  bool opened = false;
  final List<_VersionWaiter> waiters = [];
}

/// A request waiting for the editor's [version] of its document.
final class _VersionWaiter {
  _VersionWaiter(this.version);

  final int version;
  final Completer<bool> completer = Completer<bool>();
  Timer? timer;
}

/// One file watcher a server registered.
final class _Watcher {
  _Watcher({required this.pattern, required this.kinds, this.base});

  final RegExp pattern;

  /// WatchKind's bits: 1 created, 2 changed, 4 deleted.
  final int kinds;

  /// For a relative pattern, the folder it is relative to; null for a
  /// pattern over whole paths.
  final String? base;

  bool matches(String absolute, String relative) {
    final base = this.base;
    if (base == null) {
      return pattern.hasMatch(absolute) || pattern.hasMatch(relative);
    }
    if (absolute == base) {
      return pattern.hasMatch('');
    }
    if (!absolute.startsWith('$base/')) {
      return false;
    }
    return pattern.hasMatch(absolute.substring(base.length + 1));
  }

  static _Watcher? fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      return null;
    }
    final kind = json['kind'];
    final kinds = kind is int ? kind : 7;
    final glob = json['globPattern'];
    if (glob is String) {
      return _Watcher(pattern: globToRegExp(glob), kinds: kinds);
    }
    if (glob is! Map<String, Object?>) {
      return null;
    }
    final pattern = glob['pattern'];
    final baseUri = glob['baseUri'];
    final uri = switch (baseUri) {
      final String value => value,
      {'uri': final String value} => value,
      _ => null,
    };
    final base = uri == null ? null : pathOfFileUri(uri);
    if (pattern is! String || base == null) {
      return null;
    }
    final trimmed = base.length > 1 && base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    return _Watcher(
      pattern: globToRegExp(pattern),
      kinds: kinds,
      base: trimmed,
    );
  }
}
