// The typed boundary to the runtime host (Phase 4 W3,
// docs/RUNTIME_INTEGRATION.md §3): the sealed runtime's status, its install,
// its warm start, its exec audit and its size; since W4 also one-shot
// commands (`exec`) and the tool probes (`tools`).
//
// Pigeon generates the Dart client and the Kotlin interface from this file,
// as for pigeons/storage_api.dart: CI's [bootstrap] mode runs
// `dart run pigeon --input pigeons/runtime_api.dart` and commits the output,
// and every CI run generates it again and fails if the committed copies are
// stale (.github/workflows/ci.yml, "Generated code check").
//
// Every method answers through a callback (`@asyncCallback`): the host does
// the work on its own thread (RuntimeHub.kt), so no call ever blocks
// Android's main thread, and the generated Kotlin needs no coroutines
// library. `start` and `reinstall` answer at once; what happens next arrives
// through RuntimeEvents, one status snapshot per change, progress included.
import 'package:pigeon/pigeon.dart';

/// One pass of t1's ExecAudit over the runtime's prefix.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/services/runtime/native/runtime_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/dev/codeforge/app/runtime/RuntimeApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.codeforge.app.runtime'),
    dartPackageName: 'codeforge',
  ),
)
class RuntimeAuditMessage {
  RuntimeAuditMessage({
    required this.outsideApk,
    required this.outsideScripts,
    required this.shipped,
    required this.scanned,
    required this.truncated,
    required this.millis,
    required this.report,
    this.failure,
  });

  /// ELF executables outside the APK: 0 is the only healthy count.
  int outsideApk;

  /// Scripts outside the APK, which run through their interpreter.
  int outsideScripts;

  /// Executables that resolve into the APK's native library directory.
  int shipped;

  /// Paths the walk looked at.
  int scanned;

  /// Whether the walk stopped before the end (too many paths, or too long).
  bool truncated;

  int millis;

  /// ExecAudit's own report, as the user can copy it.
  String report;

  /// Why the walk could not run at all, or null.
  String? failure;
}

/// One snapshot of the runtime.
class RuntimeStatusMessage {
  RuntimeStatusMessage({
    required this.revision,
    required this.state,
    required this.done,
    required this.total,
    required this.auditing,
    this.abi,
    this.payloadId,
    this.info,
    this.problem,
    this.detail,
    this.installMs,
    this.warmStartMs,
    this.relinked,
    this.audit,
  });

  /// Grows with every change; the newest snapshot wins.
  int revision;

  /// 'unknown', 'unavailable', 'notInstalled', 'installed', 'checking',
  /// 'installing', 'ready', 'degraded' or 'failed'.
  String state;

  /// While installing: files written so far, and in all.
  int done;
  int total;

  /// Whether the exec audit is running.
  bool auditing;

  /// The payload's ABI ('arm64-v8a' or 'x86_64'); null without a payload.
  String? abi;

  /// The payload's identity (16 hex digits); null without a payload.
  String? payloadId;

  /// What the payload holds, as runtime/pins.py's JSON: the bootstrap's
  /// release, when the set was resolved, the core set's versions.
  String? info;

  /// Why it failed or is degraded (RuntimeProblem's codes in
  /// SealedRuntime.kt); null otherwise.
  String? problem;

  /// What went wrong, for the report.
  String? detail;

  /// How long this payload's install took, in ms.
  int? installMs;

  /// How long this process's warm start took, in ms.
  int? warmStartMs;

  /// Executable links the warm start rewrote.
  int? relinked;

  /// The last exec audit in this process; null before one finished.
  RuntimeAuditMessage? audit;
}

/// What the runtime occupies on the device.
class RuntimeSizeMessage {
  RuntimeSizeMessage({
    required this.prefixBytes,
    required this.prefixFiles,
    required this.nativeLibraryBytes,
    required this.apkBytes,
  });

  /// The prefix's files, each inode once.
  int prefixBytes;
  int prefixFiles;

  /// The native library directory: the executables Android extracted.
  int nativeLibraryBytes;

  /// The APK.
  int apkBytes;
}

/// One command for the runtime: a program in its bin, run once (Phase 4 W4).
class ExecRequestMessage {
  ExecRequestMessage({
    required this.program,
    required this.arguments,
    this.directory,
    this.timeoutMs,
    this.outputLimit,
  });

  /// A name in the runtime's bin (`node`, `git`); never a path.
  String program;

  List<String> arguments;

  /// The runtime's home when null; otherwise a folder inside its home or
  /// workspace.
  String? directory;

  /// The time limit (60 s when null, at most 10 minutes).
  int? timeoutMs;

  /// Bytes kept of each of stdout and stderr (256 KiB when null, 1 KiB to
  /// 1 MiB).
  int? outputLimit;
}

/// What became of a command.
class ExecResultMessage {
  ExecResultMessage({
    required this.stdout,
    required this.stderr,
    required this.stdoutBytes,
    required this.stderrBytes,
    required this.stdoutTruncated,
    required this.stderrTruncated,
    required this.durationMs,
    required this.leftovers,
    required this.remaining,
    this.exitCode,
    this.signal,
    this.failure,
    this.detail,
  });

  /// The command's exit code; null when it did not exit by itself.
  int? exitCode;

  /// The signal that ended it, when one did.
  int? signal;

  String stdout;
  String stderr;

  /// Every byte written to each, kept or not.
  int stdoutBytes;
  int stderrBytes;

  bool stdoutTruncated;
  bool stderrTruncated;

  int durationMs;

  /// Why it has no ordinary result: 'not_ready', 'bad_request',
  /// 'not_found', 'cannot_execute', 'timed_out', 'ended', 'signaled' or
  /// 'launch_failed' (CommandRunner.kt); null when it ran and exited.
  String? failure;

  String? detail;

  /// Processes ended after it: what it left running, or its whole tree when
  /// it was stopped.
  int leftovers;

  /// Processes that could not be ended: 0 unless the kernel refused.
  int remaining;
}

/// One tool's probe (Toolchain.kt).
class ToolMessage {
  ToolMessage({
    required this.tool,
    required this.packageName,
    required this.health,
    required this.millis,
    this.version,
    this.pinned,
    this.detail,
  });

  /// 'node', 'python', 'git', 'bash', 'perl', 'ruby' or 'rg'.
  String tool;

  /// The Termux package that carries it.
  String packageName;

  /// What the tool says its version is.
  String? version;

  /// Its package's pinned version.
  String? pinned;

  /// 'ok', 'mismatch', 'failed', 'missing' or 'unavailable'.
  String health;

  /// The probe's first line of output, or why it failed.
  String? detail;

  int millis;
}

/// Every tool's probe.
class ToolsMessage {
  ToolsMessage({required this.tools, required this.millis, this.failure});

  List<ToolMessage> tools;

  int millis;

  /// Why nothing was probed (the runtime is not ready), or null.
  String? failure;
}

@HostApi()
abstract class RuntimeApi {
  /// The status. The first call in a process looks whether this APK carries
  /// a runtime and whether it is installed; it never installs.
  @asyncCallback
  RuntimeStatusMessage status();

  /// Starts the runtime once per process: a warm start when this APK's
  /// payload is installed, an install otherwise, then the exec audit.
  /// Answers at once.
  @asyncCallback
  RuntimeStatusMessage start();

  /// Removes the runtime and installs it again. Answers at once.
  @asyncCallback
  RuntimeStatusMessage reinstall();

  /// Audits the installed runtime again; answers with the status after it.
  @asyncCallback
  RuntimeStatusMessage audit();

  /// Measures what the runtime occupies.
  @asyncCallback
  RuntimeSizeMessage size();

  /// Runs one command in the runtime and answers with its result (Phase 4
  /// W4). Refused with 'not_ready' unless the runtime is ready or degraded.
  @asyncCallback
  ExecResultMessage exec(ExecRequestMessage request);

  /// Probes node, python, git, bash, perl, ruby and rg: each version, and
  /// whether it is the pinned one (Phase 4 W4, gate G4).
  @asyncCallback
  ToolsMessage tools();
}

/// What the runtime host tells Dart unasked.
@FlutterApi()
abstract class RuntimeEvents {
  /// The runtime changed: its state, its progress or its audit.
  @asyncCallback
  void changed(RuntimeStatusMessage status);
}
