/// A language servers' host in memory (Phase 6 W4): the fake transport the
/// client's tests run against. Servers start at once with growing handles,
/// in a root as the host names it; what the client sends each one is
/// recorded, decoded; requests are answered as the test scripts
/// ([respond]: `initialize` and `shutdown` by default), and the test makes a
/// server speak ([deliver]) and end ([crash]). A server exits by itself
/// after `exit`, as a real one does. The real host is covered by the JVM's
/// LspHostTest and the instrumented LanguageServerTest (W3).
library;

import 'dart:async';
import 'dart:convert';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/services/contracts.dart';

import 'fake_lsp_clock.dart';

/// Where the fake host's workspaces are, as a device names them.
const String scriptedFilesRoot = '/data/data/dev.codeforge.app/files';

final class ScriptedLspService implements LspService {
  ScriptedLspService({this.clock});

  /// Stamps writes and reads, when given.
  final FakeLspClock? clock;

  final StreamController<LspIncoming> _messages =
      StreamController<LspIncoming>.broadcast();
  final StreamController<LspExit> _exits =
      StreamController<LspExit>.broadcast();
  int _nextHandle = 1;
  final Map<int, LspServerId> _running = {};

  /// Every start asked for, in order.
  final List<({LspServerId server, LspWorkspace workspace})> starts = [];

  /// Every handle stopped through the host, in order.
  final List<int> stops = [];

  /// What the client sent each server, decoded, in order.
  final Map<int, List<Map<String, Object?>>> sent = {};

  /// The next start fails with this, when set.
  LspFailure? failNextStart;

  /// What a server answers a request: a response's `result` or `error`
  /// member, or null to answer nothing (the test answers, or lets it time
  /// out). Null uses [defaultAnswer].
  Map<String, Object?>? Function(int handle, String method, Object? params)?
  respond;

  /// Whether a server exits after `exit` (a real one does).
  bool exitAfterExit = true;

  /// What the default server says it can do.
  Map<String, Object?> capabilities = const {
    'textDocumentSync': {
      'openClose': true,
      'change': 2,
      'save': {'includeText': false},
    },
  };

  @override
  bool get available => true;

  @override
  Stream<LspIncoming> get messages => _messages.stream;

  @override
  Stream<LspExit> get exits => _exits.stream;

  /// The handles of the servers running now.
  Iterable<int> get running => _running.keys;

  /// The handle of the newest server started.
  int get latest => _nextHandle - 1;

  /// The root the host gives [workspace]: a project's folder, or a copy's.
  static String rootOf(LspWorkspace workspace) => workspace.project != null
      ? '$scriptedFilesRoot/workspaces/${workspace.project}'
      : '$scriptedFilesRoot/copies/${workspace.copy}';

  @override
  Future<Result<LspStarted>> start(
    LspServerId server,
    LspWorkspace workspace,
  ) async {
    starts.add((server: server, workspace: workspace));
    final failure = failNextStart;
    if (failure != null) {
      failNextStart = null;
      return Err(failure);
    }
    final handle = _nextHandle++;
    _running[handle] = server;
    sent[handle] = [];
    return Ok(
      LspStarted(
        handle: handle,
        root: rootOf(workspace),
        bin: '/rt/usr/bin',
        serverDirectory: '/rt/codeforge/lsp/${server.id}',
      ),
    );
  }

  @override
  Future<Result<LspWritten>> send(int handle, String message) async {
    if (!_running.containsKey(handle)) {
      return const Err(
        LspFailure('No such server.', problem: LspProblem.noSuchServer),
      );
    }
    final decoded = jsonDecode(message) as Map<String, Object?>;
    sent[handle]!.add(decoded);
    final writtenUs = clock?.monotonicUs;
    final method = decoded['method'];
    final id = decoded['id'];
    if (method is String && id != null) {
      final answer = (respond ?? defaultAnswer)(
        handle,
        method,
        decoded['params'],
      );
      if (answer != null) {
        scheduleMicrotask(() {
          if (_running.containsKey(handle)) {
            deliver(handle, {'jsonrpc': '2.0', 'id': id, ...answer});
          }
        });
      }
    } else if (method == 'exit' && exitAfterExit) {
      scheduleMicrotask(() => crash(handle, end: LspEnd.exited, signal: null));
    }
    return Ok(LspWritten(writtenUs: writtenUs));
  }

  @override
  Future<Result<void>> stop(int handle) async {
    stops.add(handle);
    if (!_running.containsKey(handle)) {
      return const Err(
        LspFailure('No such server.', problem: LspProblem.noSuchServer),
      );
    }
    scheduleMicrotask(() => crash(handle, end: LspEnd.stopped, signal: null));
    return const Ok(null);
  }

  @override
  Future<Result<List<LspServerInfo>>> servers() async => Ok([
    for (final MapEntry(key: handle, value: server) in _running.entries)
      LspServerInfo(
        handle: handle,
        server: server.id,
        startedAtMs: 0,
        installMs: 0,
        received: 0,
        sent: sent[handle]?.length ?? 0,
      ),
  ]);

  /// The default server: `initialize` answers [capabilities], `shutdown`
  /// null; anything else waits for the test.
  Map<String, Object?>? defaultAnswer(
    int handle,
    String method,
    Object? params,
  ) => switch (method) {
    'initialize' => {
      'result': {
        'capabilities': capabilities,
        'serverInfo': {'name': 'scripted'},
      },
    },
    'shutdown' => {'result': null},
    _ => null,
  };

  /// Server [handle] writes [message]; the host read it at [readUs] (the
  /// clock's now when there is one).
  void deliver(int handle, Map<String, Object?> message, {int? readUs}) {
    _messages.add(
      LspIncoming(
        handle,
        jsonEncode(message),
        readUs: readUs ?? clock?.monotonicUs,
      ),
    );
  }

  /// Server [handle] ends as [end].
  void crash(
    int handle, {
    LspEnd end = LspEnd.signaled,
    int? signal = 9,
    int? exitCode,
  }) {
    final server = _running.remove(handle);
    if (server == null) {
      return;
    }
    _exits.add(
      LspExit(
        handle: handle,
        server: server.id,
        end: end,
        signal: signal,
        exitCode: exitCode ?? (end == LspEnd.exited ? 0 : null),
      ),
    );
  }

  /// The methods the client sent server [handle], in order.
  List<String> methods(int handle) => [
    for (final message in sent[handle] ?? const <Map<String, Object?>>[])
      if (message['method'] case final String method) method,
  ];

  /// The params of every [method] the client sent server [handle].
  List<Map<String, Object?>> paramsOf(int handle, String method) => [
    for (final message in sent[handle] ?? const <Map<String, Object?>>[])
      if (message['method'] == method) _mapOf(message['params']),
  ];

  /// The answers the client sent server [handle]'s own requests.
  List<Map<String, Object?>> answers(int handle) => [
    for (final message in sent[handle] ?? const <Map<String, Object?>>[])
      if (!message.containsKey('method')) message,
  ];

  Future<void> dispose() async {
    await _messages.close();
    await _exits.close();
  }

  static Map<String, Object?> _mapOf(Object? value) =>
      value is Map<String, Object?> ? value : const {};
}
