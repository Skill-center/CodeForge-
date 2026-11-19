// The typed boundary to the terminal host (Phase 5 W2, PHASE_5_PLAN W2):
// terminal sessions on the sealed runtime (android/…/terminal/TerminalHost.kt,
// over runtime/Terminals.kt and runtime/TerminalSession.kt). Dart names a
// session's folder by a project's folder name and its program by a name in
// the runtime's bin, never by a path; Kotlin checks both again
// (docs/SECURITY.md §2.1, E1, E3 and E8).
//
// Pigeon generates the Dart client and the Kotlin interface from this file,
// as for pigeons/runtime_api.dart: CI's bootstrap mode runs
// `dart run pigeon --input pigeons/terminal_api.dart` and commits the
// output, and every CI run generates it again and fails if the committed
// copies are stale (.github/workflows/ci.yml, "Generated code check").
//
// Output reaches Dart through TerminalEvents, a Flutter API, as the runtime's
// and the search's events do. W2 chose it over an event channel: one
// mechanism for every host, typed, in order on the main thread; and the
// credit window bounds what is in flight (Dart acknowledges what it has
// drawn), so a channel's own buffering would add nothing. Every method
// answers through a callback (`@asyncCallback`), so the generated Kotlin
// needs no coroutines library.
import 'package:pigeon/pigeon.dart';

/// What a terminal session should be (docs/TERMINAL_ARCHITECTURE.md §1).
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/services/terminal/native/terminal_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/dev/codeforge/app/terminal/TerminalApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.codeforge.app.terminal'),
    dartPackageName: 'codeforge',
  ),
)
class TerminalSpecMessage {
  TerminalSpecMessage({
    required this.arguments,
    required this.environment,
    required this.rows,
    required this.columns,
    this.project,
    this.program,
    this.bufferBytes,
    this.label,
  });

  /// A project's folder name in `<filesDir>/workspaces`, which Kotlin
  /// resolves itself; the runtime's home when null.
  String? project;

  /// A name in the runtime's bin; null is bash, interactive, with
  /// CodeForge's rc file.
  String? program;

  /// The program's arguments; bash's are CodeForge's own.
  List<String> arguments;

  /// Variables to add; the runtime's own and any LD_* are refused.
  Map<String, String> environment;

  int rows;
  int columns;

  /// The output kept while no view is attached (1 MiB when null).
  int? bufferBytes;

  /// The session's name; the program's when null.
  String? label;
}

/// One terminal session, as it is now.
class TerminalInfoMessage {
  TerminalInfoMessage({
    required this.id,
    required this.label,
    required this.state,
    required this.rows,
    required this.columns,
    required this.received,
    required this.leftovers,
    required this.remaining,
    this.exitCode,
    this.signal,
    this.failure,
    this.detail,
  });

  int id;
  String label;

  /// 'starting', 'running' or 'exited'.
  String state;

  int rows;
  int columns;

  /// Every byte the session has written so far.
  int received;

  /// The shell's exit code, when it exited.
  int? exitCode;

  /// The signal that ended the shell, when one did.
  int? signal;

  /// How it ended when not by its shell's own exit: 'ended', 'signaled',
  /// 'lost', 'cannot_start', 'terminal_failed' or 'launch_failed'
  /// (TerminalSession.kt).
  String? failure;

  String? detail;

  /// Processes ended with it: what the shell left, or its whole tree.
  int leftovers;

  /// Processes that could not be ended.
  int remaining;
}

/// A started session, or why none started: 'not_ready', 'bad_request',
/// 'not_found', 'too_many' or 'launch_failed'.
class TerminalStartMessage {
  TerminalStartMessage({this.session, this.failure, this.detail});

  TerminalInfoMessage? session;
  String? failure;
  String? detail;
}

/// What a view gets when it attaches: the buffer's content, from [offset].
class TerminalReplayMessage {
  TerminalReplayMessage({
    required this.offset,
    required this.bytes,
    this.failure,
  });

  int offset;
  Uint8List bytes;

  /// 'no_such_session', or null.
  String? failure;
}

@HostApi()
abstract class TerminalApi {
  /// Starts a session with this engine as its view from its first byte.
  /// Answers once its process has started, or why it did not.
  @asyncCallback
  TerminalStartMessage start(TerminalSpecMessage spec);

  /// The sessions, running and exited, oldest first.
  @asyncCallback
  List<TerminalInfoMessage> sessions();

  /// Queues [bytes] as typed input. Null, or why not: 'no_such_session',
  /// 'not_running' or 'input_full'.
  @asyncCallback
  String? write(int sessionId, Uint8List bytes);

  /// Queues the window's new size. Null, or why not.
  @asyncCallback
  String? resize(int sessionId, int rows, int columns);

  /// The view has drawn everything before [offset]: the session may read
  /// that much further (credit flow control).
  @asyncCallback
  void acknowledge(int sessionId, int offset);

  /// This engine becomes the session's view: its buffer now, its output
  /// from there on.
  @asyncCallback
  TerminalReplayMessage attach(int sessionId);

  /// The session reads into its buffer without a view from now on.
  @asyncCallback
  void detach(int sessionId);

  /// Ends the session with everything it started. Null, or why not:
  /// 'no_such_session' or 'not_running'.
  @asyncCallback
  String? end(int sessionId);

  /// The user's End all: ends every session and waits for them; answers
  /// how many still run.
  @asyncCallback
  int endAll();

  /// Forgets an exited session and its buffer. Null, or why not:
  /// 'no_such_session' or 'still_running'.
  @asyncCallback
  String? remove(int sessionId);
}

/// What the terminal host tells Dart unasked.
@FlutterApi()
abstract class TerminalEvents {
  /// A session's output, from [offset] in its stream: at most one batch
  /// every 16 ms, the first bytes after a quiet moment at once.
  @asyncCallback
  void output(int sessionId, int offset, Uint8List bytes);

  /// A session started or exited.
  @asyncCallback
  void changed(TerminalInfoMessage info);
}
