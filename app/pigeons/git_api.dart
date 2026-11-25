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
//
// Since Phase 7 W3 a remote run (clone, fetch, pull, push) may ask Dart for
// a credential while it runs: git's credential helper or ssh's askpass
// reaches the host, which answers from the credential store (the Keystore's
// key) or sends GitEvents.credentialRequested; Dart's dialog answers with
// GitApi.answerCredential. A token crosses this boundary only in that
// answer, never in a run's arguments. The store lists hosts and user names
// (GitApi.accounts), never a secret.
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

/// What a remote run asks the user (Phase 7 W3): a token for a host over
/// HTTPS, or whether to trust a host ssh has not seen.
class GitCredentialPromptMessage {
  GitCredentialPromptMessage({
    required this.id,
    required this.runId,
    required this.kind,
    required this.host,
    this.username,
    this.fingerprint,
    this.keyType,
  });

  /// Answered with this id ([GitApi.answerCredential]).
  int id;
  int runId;

  /// 'https' (a user name and a token) or 'host_key' (trust a new host).
  String kind;

  /// git's host (`github.com`, `127.0.0.1:8080`), or ssh's.
  String host;

  /// The user name the URL names, if any.
  String? username;

  /// A new host's key: its SHA-256 fingerprint and its type (`ED25519`).
  String? fingerprint;
  String? keyType;
}

/// The user's answer to a prompt.
class GitCredentialAnswerMessage {
  GitCredentialAnswerMessage({
    required this.id,
    required this.accepted,
    required this.remember,
    this.username,
    this.secret,
  });

  int id;

  /// False: cancelled, or the host not trusted.
  bool accepted;
  String? username;

  /// The token or password: one line, never logged.
  String? secret;

  /// Keep it in the store once the host accepts it.
  bool remember;
}

/// A stored credential as Settings lists it: never its secret.
class GitAccountMessage {
  GitAccountMessage({
    required this.kind,
    required this.host,
    required this.username,
    required this.updatedAt,
  });

  /// 'https' or 'ssh_key'.
  String kind;
  String host;
  String username;

  /// Milliseconds since the epoch.
  int updatedAt;
}

/// CodeForge's SSH key's public half.
class GitSshKeyMessage {
  GitSshKeyMessage({
    required this.publicKey,
    required this.fingerprint,
    required this.comment,
  });

  /// `ssh-ed25519 AAAA... comment`, to copy into a host's settings.
  String publicKey;

  /// `SHA256:...`, as ssh-keygen prints it.
  String fingerprint;
  String comment;
}

/// A new key, or why not.
class GitSshKeyResultMessage {
  GitSshKeyResultMessage({this.key, this.failure, this.detail});

  GitSshKeyMessage? key;

  /// 'not_ready', 'bad_request' or 'launch_failed'.
  String? failure;
  String? detail;
}

/// The answer to a run: null [failure] when it runs, and its events follow.
class GitStartMessage {
  GitStartMessage({this.failure, this.detail});

  /// Why it does not run: 'not_ready', 'bad_request', 'refused',
  /// 'no_such_project', 'exists', 'busy' or 'launch_failed'
  /// (git/GitCommands.kt).
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
  /// 'bad_request', 'launch_failed', 'timed_out', 'stopped', 'signaled',
  /// 'too_large', or 'exists' (a clone's name taken meanwhile). Null when
  /// git exited by itself, or was ended at the cap ([truncated]).
  String? failure;

  String? detail;

  /// What git wrote to stderr, without its progress, up to 64 KiB.
  String stderr;

  /// Records passed on, and their characters.
  int records;
  int chars;

  /// Ended at the run's cap of records, or the host's of 64 MiB: what came
  /// is a beginning, with no exit code, or git's when it had finished
  /// writing before the end reached it.
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

  /// Answers a prompt (Phase 7 W3); one that no run waits for any more is
  /// dropped.
  @asyncCallback
  void answerCredential(GitCredentialAnswerMessage answer);

  /// The stored credentials' hosts and user names, newest first.
  @asyncCallback
  List<GitAccountMessage> accounts();

  /// Removes a stored credential; false when there was none.
  @asyncCallback
  bool removeAccount(String kind, String host, String username);

  /// CodeForge's SSH key, or null.
  @asyncCallback
  GitSshKeyMessage? sshKey();

  /// Makes a new SSH key named [comment], replacing CodeForge's last one.
  @asyncCallback
  GitSshKeyResultMessage createSshKey(String comment);

  /// Removes the SSH key and its passphrase; false when there was none.
  @asyncCallback
  bool deleteSshKey();
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

  /// A remote run asks the user (Phase 7 W3); answered through
  /// [GitApi.answerCredential].
  @asyncCallback
  void credentialRequested(GitCredentialPromptMessage prompt);

  /// Prompt [id] is no longer waited for (its run ended, or timed out): its
  /// dialog closes.
  @asyncCallback
  void credentialWithdrawn(int id);

  /// A host refused the credential stored for [host] and [username] during
  /// run [runId], and it was removed from the store.
  @asyncCallback
  void credentialRejected(int runId, String host, String username);
}
