// The typed boundary to the Git host (Phase 7 W2, PHASE_7_PLAN W2;
// docs/adr/0016-git.md): the runtime's own git, run by Kotlin
// (android/…/git/GitHost.kt over git/GitRunner.kt, which checks every
// command against git/GitCommands.kt). Dart names a project by its folder's
// name, never a path; Kotlin resolves it inside the projects' folder, links
// resolved (docs/SECURITY.md §2.1, E3), and refuses any operation or option
// it does not list.
//
// Kotlin is a supervised runner: it starts one git command, cuts its stdout
// into records (NUL-separated for git's `-z` output, lines, or the whole
// output), passes progress from stderr, can stop it, and says how it ended.
// Dart owns the meaning: the parsers in lib/core/git/ and the controller.
//
// Pigeon generates the Dart client and the Kotlin interface from this file,
// as for pigeons/lsp_api.dart: CI's bootstrap mode runs
// `dart run pigeon --input pigeons/git_api.dart` and commits the output, and
// every CI run generates it again and fails if the committed copies are
// stale (.github/workflows/ci.yml, "Generated code check").
//
// `run` answers at once: the command runs, or why not. A running command's
// records, progress and exit reach Dart through GitEvents on the main thread,
// in order: batches of records, then one exit, whatever happened. Every
// method answers through a callback (`@asyncCallback`), so the generated
// Kotlin needs no coroutines library.
import 'package:pigeon/pigeon.dart';

/// One git command: its operation and arguments, and where it runs.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/services/git/native/git_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/app/src/main/kotlin/dev/codeforge/app/git/GitApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.codeforge.app.git'),
    dartPackageName: 'codeforge',
  ),
)
class GitRunMessage {
  GitRunMessage({
    required this.runId,
    required this.operation,
    required this.arguments,
    this.project,
    this.maxRecords,
  });

  /// Chosen by Dart; every event of this run carries it.
  int runId;

  /// A project's folder name; null for the identity (`config --global`),
  /// which lives in the runtime's home and is shared with the terminal.
  String? project;

  /// `status`, `add`, `commit`, ... (git/GitCommands.kt lists them).
  String operation;

  /// After the operation: its options, then `--` and paths relative to the
  /// project.
  List<String> arguments;

  /// Records to pass on before the command is ended, truncated (1,000,000
  /// when null, and never more).
  int? maxRecords;
}

/// The answer to a run: null [failure] when it runs, and its events follow.
class GitStartMessage {
  GitStartMessage({this.failure, this.detail});

  /// Why it does not run: 'not_ready', 'bad_request', 'refused',
  /// 'no_such_project', 'busy' or 'launch_failed' (git/GitCommands.kt).
  String? failure;

  /// What was wrong, in words; never a path or an argument.
  String? detail;
}

/// How a run ended, once, after its last records.
class GitExitMessage {
  GitExitMessage({
    required this.runId,
    required this.operation,
    required this.stderr,
    required this.records,
    required this.chars,
    required this.truncated,
    required this.elapsedMs,
    this.exitCode,
    this.failure,
    this.detail,
  });

  int runId;
  String operation;

  /// git's exit code when it exited by itself; null when it was ended or
  /// never ran.
  int? exitCode;

  /// When the host ended it or could not run it: 'not_ready',
  /// 'bad_request', 'launch_failed', 'timed_out', 'stopped', 'signaled' or
  /// 'too_large'. Null with no exit code when it was ended at the cap
  /// ([truncated]): what came is a beginning.
  String? failure;

  String? detail;

  /// What git wrote to stderr, without its progress, up to 64 KiB.
  String stderr;

  /// Records passed on, and their characters.
  int records;
  int chars;

  /// Ended at the run's cap of records, or the host's of 64 MiB.
  bool truncated;

  int elapsedMs;
}

@HostApi()
abstract class GitApi {
  /// Starts [request]. Answers at once.
  @asyncCallback
  GitStartMessage run(GitRunMessage request);

  /// Stops run [runId] with everything it started; its exit follows. False
  /// when it is not running.
  @asyncCallback
  bool stop(int runId);
}

/// What the Git host tells Dart unasked.
@FlutterApi()
abstract class GitEvents {
  /// More of run [runId]'s records, in order.
  @asyncCallback
  void output(int runId, List<String> records);

  /// A line of git's progress (`Updating files:  45% (450/1000)`), at most
  /// one redrawn line per 100 ms; [closing] ends a run of them.
  @asyncCallback
  void progress(int runId, String text, bool closing);

  /// Run [runId] ended; nothing of it follows.
  @asyncCallback
  void exited(GitExitMessage exit);
}
