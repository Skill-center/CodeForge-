/// Typed failure taxonomy for CodeForge (docs/ARCHITECTURE.md §2.3).
///
/// Every boundary crossing returns a [Result] instead of throwing raw
/// exceptions; failures carry a kind and a human-readable message, never a
/// bare exit code (a discipline inherited from the audited runtime).
library;

/// Base class for all typed failures.
sealed class Failure {
  const Failure(this.message, {this.cause});

  /// Human-readable description, safe to show in the UI.
  final String message;

  /// Optional underlying error, for logs only (may contain internals).
  final Object? cause;

  /// Stable machine-readable kind, used in logs and diagnostics.
  String get kind;

  @override
  String toString() => '$kind: $message';
}

/// Filesystem / storage access failed or was not permitted.
final class StorageFailure extends Failure {
  const StorageFailure(super.message, {super.cause});

  @override
  String get kind => 'storage';
}

/// Why a file operation was refused. Some of these lead to a question
/// rather than an error: [exists] (replace it?) and [changedOnDisk]
/// (overwrite it?).
enum FileProblem {
  /// No file at that path.
  notFound,

  /// Something already exists at that path.
  exists,

  /// The file changed on disk since it was read: saving would lose that.
  changedOnDisk,

  /// Not UTF-8 text: binary data, malformed UTF-8 or another encoding.
  notText,

  /// Larger than the editor accepts.
  tooLarge,

  /// Not a valid workspace-relative path.
  invalidPath,

  /// Resolves (through a symbolic link) to a place outside the workspace.
  outsideWorkspace,

  /// A folder where a file was expected, or the reverse.
  wrongType,

  /// Another open tab holds that file.
  inUse,

  /// The storage itself failed (permissions, disk full, I/O errors).
  io,

  /// The workspace's folder is gone: deleted, moved or renamed, or its
  /// storage removed (Phase 3: folders from shared storage).
  folderMissing,

  /// The app no longer has access to the workspace's folder: its grant was
  /// released or revoked.
  accessLost,

  /// The storage did not answer in time.
  timeout,

  /// The storage can't do that: a folder granted read-only, or a provider
  /// without the operation.
  unsupported,

  /// The storage gave a new or renamed item another name than the one
  /// asked for; the change was undone.
  nameChanged,
}

/// A file could not be read or written. [problem] tells the app how to
/// react; [message] is what the user is told.
final class FileFailure extends Failure {
  const FileFailure(super.message, {required this.problem, super.cause});

  final FileProblem problem;

  @override
  String get kind => 'file';
}

/// A platform/WebView bridge message was invalid or the channel failed.
final class BridgeFailure extends Failure {
  const BridgeFailure(super.message, {super.cause});

  @override
  String get kind => 'bridge';
}

/// The Linux runtime is unavailable, unhealthy, or misconfigured.
final class RuntimeFailure extends Failure {
  const RuntimeFailure(super.message, {super.cause});

  @override
  String get kind => 'runtime';
}

/// Why a terminal session did not start, why a call about one was refused,
/// or how one ended other than by its shell's own exit (Phase 5 W2). Each
/// [code] is the terminal host's (TerminalSession.kt's TerminalFailure).
enum TerminalProblem {
  /// The runtime is not installed and started, or is being installed.
  notReady('not_ready'),

  /// The host refused the request: a path for a program, a protected
  /// variable, a folder outside the projects.
  badRequest('bad_request'),

  /// No such program in the runtime: bash itself, or the one asked for.
  notFound('not_found'),

  /// Every place for a terminal is taken (eight sessions run).
  tooMany('too_many'),

  /// The shell is there and could not be executed.
  cannotStart('cannot_start'),

  /// No pseudo-terminal could be opened.
  terminalFailed('terminal_failed'),

  /// The runtime's launcher could not run.
  launchFailed('launch_failed'),

  /// The app ended it (a request, End all, a reinstall).
  ended('ended'),

  /// A signal ended the shell by itself.
  signaled('signaled'),

  /// The relay between the app and the terminal stopped.
  lost('lost'),

  /// No session has that id.
  noSuchSession('no_such_session'),

  /// The session has ended, so it takes no more input.
  notRunning('not_running'),

  /// More input waits than a session queues.
  inputFull('input_full'),

  /// The session still runs, so it cannot be forgotten.
  stillRunning('still_running'),

  /// Android ended the app while the session ran, and its processes ended
  /// with it (Phase 5 W5): a tombstone after the next start.
  system('system'),

  /// No terminal host here: tests, or a build without one.
  unavailable('unavailable'),

  /// A code this build does not know.
  unknown('unknown');

  const TerminalProblem(this.code);

  final String code;

  /// The problem for a host's [code]; [unknown] for any other.
  static TerminalProblem fromCode(String? code) {
    for (final problem in values) {
      if (problem.code == code) {
        return problem;
      }
    }
    return unknown;
  }
}

/// A terminal session could not start, a call about one was refused, or
/// it ended other than by its shell's own exit. [problem] tells the app
/// how to react; [message] is what the user is told.
final class TerminalFailure extends Failure {
  const TerminalFailure(super.message, {required this.problem, super.cause});

  final TerminalProblem problem;

  @override
  String get kind => 'terminal';
}

/// Why a language server, or a call to one, failed (Phase 6 W4): the host's
/// codes (runtime/LspHost.kt's LspFailure, pigeons/lsp_api.dart), then the
/// client's own.
enum LspProblem {
  /// The runtime is not ready, or is being installed.
  notReady('not_ready'),

  /// A server or a workspace the host refused.
  badRequest('bad_request'),

  /// This APK carries no such server.
  notInApk('not_in_apk'),

  /// The server's files in the APK are damaged.
  damaged('damaged'),

  /// The device could not store the server.
  storage('storage'),

  /// Two servers run already.
  tooMany('too_many'),

  /// This server runs already: [LspFailure.running] names it.
  alreadyRunning('already_running'),

  /// The runtime's launcher or its node could not start it.
  launchFailed('launch_failed'),

  /// No server has that handle.
  noSuchServer('no_such_server'),

  /// The server is ending or has ended.
  notRunning('not_running'),

  /// Too much waits for the server's stdin already.
  queueFull('queue_full'),

  /// The server did not answer in time.
  timeout('timeout'),

  /// Whoever asked moved on.
  cancelled('cancelled'),

  /// The server ended and is starting again.
  restarting('restarting'),

  /// The server is off.
  stopped('stopped'),

  /// The server answered with an error ([LspFailure.errorCode]).
  serverError('server_error'),

  /// No host here (`flutter test`), or the host did not answer.
  unavailable('unavailable'),

  unknown('unknown');

  const LspProblem(this.code);

  final String code;

  static LspProblem fromCode(String? code) {
    for (final problem in values) {
      if (problem.code == code) {
        return problem;
      }
    }
    return unknown;
  }
}

/// A language server, or a call to one, that failed (Phase 6 W4).
final class LspFailure extends Failure {
  const LspFailure(
    super.message, {
    required this.problem,
    this.running,
    this.errorCode,
    super.cause,
  });

  final LspProblem problem;

  /// For [LspProblem.alreadyRunning]: the handle of the server that runs.
  final int? running;

  /// For [LspProblem.serverError]: the server's JSON-RPC error code.
  final int? errorCode;

  @override
  String get kind => 'lsp';
}

/// A child process failed to start, misbehaved, or exited unexpectedly.
final class ProcessFailure extends Failure {
  const ProcessFailure(super.message, {this.exitCode, super.cause});

  final int? exitCode;

  @override
  String get kind => 'process';
}

/// Anything not covered above. Use sparingly; prefer a specific kind.
final class UnexpectedFailure extends Failure {
  const UnexpectedFailure(super.message, {super.cause});

  @override
  String get kind => 'unexpected';
}

/// A value or a typed failure — the only error currency across services.
sealed class Result<T> {
  const Result();
}

/// Successful result carrying [value].
final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

/// Failed result carrying a typed [failure].
final class Err<T> extends Result<T> {
  const Err(this.failure);

  final Failure failure;
}

/// Convenience accessors for [Result].
extension ResultX<T> on Result<T> {
  bool get isOk => this is Ok<T>;

  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => null,
  };

  Failure? get failureOrNull => switch (this) {
    Err<T>(:final failure) => failure,
    Ok<T>() => null,
  };

  /// Unwrap or throw the failure — for tests and bootstrap paths only.
  T get orThrow => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>(:final failure) => throw failure,
  };
}
