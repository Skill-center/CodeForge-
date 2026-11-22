// The typed boundary to the language servers' host (Phase 6 W3,
// PHASE_6_PLAN W3): servers on the sealed runtime
// (android/…/lsp/LanguageServerHost.kt, over runtime/LspHost.kt). Dart names
// a server by its id and its workspace by a project's folder name or a
// folder's copy id, never by a path; Kotlin checks both again
// (docs/SECURITY.md §2.1, E3).
//
// Kotlin is a supervised pipe: it starts a server, carries whole messages
// both ways (LSP's base protocol is framed and unframed in Kotlin, so Dart
// never sees part of a message), stops it, and says how it ended. Dart owns
// the protocol (W4): JSON-RPC, the handshake, the documents, the restarts.
//
// Pigeon generates the Dart client and the Kotlin interface from this file,
// as for pigeons/terminal_api.dart: CI's bootstrap mode runs
// `dart run pigeon --input pigeons/lsp_api.dart` and commits the output, and
// every CI run generates it again and fails if the committed copies are
// stale (.github/workflows/ci.yml, "Generated code check").
//
// Messages and exits reach Dart through LspEvents, a Flutter API, in order on
// the main thread, as the terminal's output does. Every method answers
// through a callback (`@asyncCallback`), so the generated Kotlin needs no
// coroutines library.
import 'package:pigeon/pigeon.dart';

/// A started server, or why none started: 'not_ready', 'bad_request',
/// 'not_in_apk', 'damaged', 'storage', 'too_many', 'already_running' or
/// 'launch_failed' (runtime/LspHost.kt).
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/services/lsp/native/lsp_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/app/src/main/kotlin/dev/codeforge/app/lsp/LspApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.codeforge.app.lsp'),
    dartPackageName: 'codeforge',
  ),
)
class LspStartMessage {
  LspStartMessage({this.handle, this.failure, this.detail, this.running});

  /// The server's handle, when it started.
  int? handle;

  String? failure;
  String? detail;

  /// For 'already_running': the handle of the server that runs.
  int? running;
}

/// One running server, as it is now.
class LspServerMessage {
  LspServerMessage({
    required this.handle,
    required this.server,
    required this.startedAtMs,
    required this.installMs,
    required this.received,
    required this.sent,
    this.project,
    this.copy,
    this.pssKib,
    this.rssKib,
    this.processes,
  });

  int handle;

  /// The server's id: 'pyright' or 'typescript'.
  String server;

  /// Its workspace: a project's folder name, or a folder's copy id.
  String? project;
  String? copy;

  /// When it started, in milliseconds since the epoch.
  int startedAtMs;

  /// How long its install took before its start; 0 when it was installed.
  int installMs;

  /// Messages it wrote, and messages written to it.
  int received;
  int sent;

  /// Its process tree's memory as last read (every 10 s), in KiB.
  int? pssKib;
  int? rssKib;
  int? processes;
}

/// How a server ended: [end] is 'exited', 'signaled', 'stopped', 'memory'
/// (stopped to free memory), 'broken' (it wrote something that is not the
/// base protocol) or 'lost'.
class LspExitMessage {
  LspExitMessage({
    required this.handle,
    required this.server,
    required this.end,
    required this.stderr,
    required this.leftovers,
    required this.remaining,
    this.exitCode,
    this.signal,
    this.detail,
  });

  int handle;
  String server;
  String end;
  int? exitCode;
  int? signal;
  String? detail;

  /// The last 64 KiB it wrote to stderr.
  String stderr;

  /// Processes of its tree ended after it, and processes that could not be.
  int leftovers;
  int remaining;
}

@HostApi()
abstract class LspApi {
  /// Starts [server] in a project ([project]) or a folder's copy ([copy]),
  /// installing it first the first time. Answers once its process has
  /// started, or why it did not.
  @asyncCallback
  LspStartMessage start(String server, String? project, String? copy);

  /// Queues [message], one JSON-RPC message, for the server's stdin. Null, or
  /// why not: 'no_such_server', 'not_running', 'bad_request' (over 16 MiB) or
  /// 'queue_full'.
  @asyncCallback
  String? send(int handle, String message);

  /// Stops the server with its whole tree; its exit follows. Null, or why
  /// not: 'no_such_server' or 'not_running'.
  @asyncCallback
  String? stop(int handle);

  /// The servers that run, oldest first.
  @asyncCallback
  List<LspServerMessage> servers();
}

/// What the language servers' host tells Dart unasked.
@FlutterApi()
abstract class LspEvents {
  /// One whole message a server wrote.
  @asyncCallback
  void received(int handle, String json);

  /// A server ended; nothing more comes from it.
  @asyncCallback
  void exited(LspExitMessage exit);
}
