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
