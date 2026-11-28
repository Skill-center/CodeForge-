/// Git on real targets (Phase 7 W6, gate G6; PHASE_7_PLAN W6), shared by
/// the emulator gate's git group (git_test.dart) and Test Lab's phone
/// (phone_git_test.dart).
///
/// - **The local server** ([GitRemoteServer]): W1's `git http-backend`
///   behind Basic authentication, in the runtime's own python on
///   127.0.0.1, exactly as the instrumented GitRemoteTest serves it. The
///   app clones, pushes and pulls through it like any other host, so the
///   credential dialog, the Keystore's store and the progress dialog are
///   the real ones; no network leaves the device.
/// - **The large repository** ([writeLargeRepository]): 10,000 files in
///   folders of 100, as the runtime's GitTest generates them.
/// - **The status** ([measureStatuses]): the panel's own refresh, timed
///   from the ask to the frame that draws it, [statusSamples] times. The
///   owner's budget of 2026-11-23: 500 ms at the 95th percentile on the
///   Pixel 8a (git alone took 134 ms in W1).
/// - **The frames** ([measureFrames]): Flutter's frames while a status, a
///   clone or a commit runs — the terminal flood's rule, at most 5 % over
///   32 ms and none frozen (terminal_measure.dart's [UiFrames]).
/// - **The token** ([SecretSweep]): the gate looks for it in the app's
///   logs, the runtime's home, the project and the processes' arguments
///   and environments, while git runs and after it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;

import 'package:codeforge/application/git/git_controller.dart';
import 'package:codeforge/application/workspace_switcher.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'smoke_test.dart' show pumpUntil;
import 'terminal_measure.dart' show UiFrames, percentile, withFramesDrawn;

/// The owner's budget of 2026-11-23 (PHASE_7_PLAN §10 item 4): the
/// 10,000-file repository's status shown in the app within 500 ms at the
/// 95th percentile on the phone.
const double statusBudgetMs = 500;

/// How many statuses the figures come from.
const int statusSamples = 20;

/// The large repository: 10,000 files, in folders of 100 (GitTest's shape).
const int largeFileCount = 10000;
const int filesPerFolder = 100;

/// Who the gate's commits are by, in the runtime's home and on the server.
const String gateName = 'CodeForge Gate';
const String gateEmail = 'gate@codeforge.invalid';

/// The user name the local server takes with the run's token.
const String serverUser = 'gate';

/// Everything the server keeps, inside the runtime's home: the bare
/// repository it serves, the seed it was made from, the other working
/// copy that stands for somebody else, and the script itself.
const String serverFolder = 'git-gate';

/// The script's name, which the gate also looks for in `pkill`.
const String serverScript = 'codeforge-git-gate-server.py';

double _round1(num value) => (value * 10).round() / 10;

/// A token of 16 random bytes, in hex: this run's, and the one the gate
/// then looks for everywhere.
String freshToken() {
  final random = math.Random.secure();
  return [
    for (var i = 0; i < 16; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// git with the gate's identity and no pager, as the runtime's own tests
/// run it: an identity on the command line, never a global config to tidy
/// up afterwards.
const List<String> gitHousekeeping = [
  '-c',
  'core.pager=cat',
  '-c',
  'init.defaultBranch=main',
  '-c',
  'user.name=$gateName',
  '-c',
  'user.email=$gateEmail',
  '-c',
  'commit.gpgsign=false',
  '-c',
  'gc.auto=0',
];

/// Runs [program] in the runtime; fails the test unless it exits 0.
Future<ExecResult> runtimeOk(
  RuntimeService runtime,
  String program,
  List<String> arguments, {
  String? directory,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final result = await runtime.exec(
    program,
    arguments,
    directory: directory,
    timeout: timeout,
  );
  final value = result.valueOrNull;
  if (value == null || !value.succeeded) {
    fail(
      '$program ${arguments.join(' ')} '
      '(in ${directory ?? 'the runtime home'}): $result '
      '${value == null ? '' : 'exit=${value.exitCode} '
                'failure=${value.failure?.name} ${value.stderr}'}',
    );
  }
  return value;
}

/// git in [directory], with the gate's identity; fails unless it exits 0.
Future<ExecResult> gitOk(
  RuntimeService runtime,
  String directory,
  List<String> arguments, {
  Duration timeout = const Duration(minutes: 5),
}) => runtimeOk(
  runtime,
  'git',
  [...gitHousekeeping, ...arguments],
  directory: directory,
  timeout: timeout,
);

/// The runtime's home, as its own processes see it (`$HOME`).
Future<String> runtimeHome(RuntimeService runtime) async {
  final answer = await runtimeOk(runtime, 'bash', [
    '-c',
    r'printf %s "$HOME"',
  ], timeout: const Duration(seconds: 60));
  final home = answer.stdout.trim();
  expect(home, startsWith('/'), reason: 'the runtime home: ${answer.stdout}');
  return home;
}

/// W1's server, kept verbatim from the instrumented GitRemoteTest
/// (android/…/git/GitRemoteTest.kt): `git http-backend` behind Basic
/// authentication on 127.0.0.1, in the runtime's python.
const String serverPython = r'''
import http.server
import os
import subprocess
import sys

root, port_file, credential_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(credential_file, encoding="ascii") as handle:
    expected = "Basic " + handle.read().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return b"".join(chunks)
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def answer(self, status, headers, payload):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def serve(self):
        data = self.body()
        if self.headers.get("Authorization", "") != expected:
            self.answer(401, [("WWW-Authenticate", 'Basic realm="codeforge-gate"')], b"authentication required\n")
            return
        path, _, query = self.path.partition("?")
        env = dict(os.environ)
        env.update({
            "GIT_PROJECT_ROOT": root,
            "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "REQUEST_METHOD": self.command,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(data)),
            "REMOTE_USER": "gate",
            "REMOTE_ADDR": "127.0.0.1",
        })
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        out = subprocess.run(["git", "http-backend"], input=data, env=env, capture_output=True).stdout
        separator, skip = out.find(b"\r\n\r\n"), 4
        if separator < 0:
            separator, skip = out.find(b"\n\n"), 2
        head, payload = (out[:separator], out[separator + skip:]) if separator >= 0 else (b"", out)
        status, headers = 200, []
        for line in head.splitlines():
            name, _, value = line.decode("latin-1").partition(":")
            if name.lower() == "status":
                status = int(value.strip().split()[0])
            elif name and name.lower() != "content-length":
                headers.append((name, value.strip()))
        self.answer(status, headers, payload)

    do_GET = serve
    do_POST = serve


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w", encoding="ascii") as handle:
    handle.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
''';

/// A repository served over HTTP on this device, with a token to sign in
/// with: everything the app's remote work needs, and nothing outside.
final class GitRemoteServer {
  GitRemoteServer._(
    this._runtime,
    this.folder, {
    required this.port,
    required this.url,
    required this.user,
    required this.token,
    required this.startMs,
    required Future<Result<ExecResult>> running,
  }) : _running = running;

  /// Builds the bare repository, then serves it. [seed] is the
  /// repository's first files, committed on `main`; [seedRepository] is a
  /// repository that already exists (the phone's 10,000-file one), which
  /// is served as it is instead.
  static Future<GitRemoteServer> start(
    RuntimeService runtime, {
    required String user,
    required String token,
    Map<String, String> seed = const {'README.md': 'served\n'},
    String? seedRepository,
  }) async {
    final watch = Stopwatch()..start();
    final home = await runtimeHome(runtime);
    final folder = Directory('$home/$serverFolder');
    if (folder.existsSync()) {
      folder.deleteSync(recursive: true);
    }
    folder.createSync(recursive: true);
    var seedPath = seedRepository ?? '';
    if (seedRepository == null) {
      seedPath = '${folder.path}/seed';
      Directory(seedPath).createSync(recursive: true);
      for (final MapEntry(:key, :value) in seed.entries) {
        File('$seedPath/$key')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(value);
      }
      await gitOk(runtime, seedPath, ['init', '-q', '--initial-branch=main']);
      await gitOk(runtime, seedPath, ['add', '-A']);
      await gitOk(runtime, seedPath, ['commit', '-q', '-m', 'Seed']);
    }
    final servedPath = '${folder.path}/served';
    Directory(servedPath).createSync(recursive: true);
    await gitOk(runtime, servedPath, [
      'clone',
      '-q',
      '--bare',
      seedPath,
      'repo.git',
    ], timeout: const Duration(minutes: 8));
    await gitOk(runtime, '$servedPath/repo.git', [
      'config',
      'http.receivepack',
      'true',
    ]);

    final script = File('${folder.path}/$serverScript')
      ..writeAsStringSync(serverPython);
    final credentials = File('${folder.path}/credentials')
      ..writeAsStringSync(base64.encode(utf8.encode('$user:$token')));
    final portFile = File('${folder.path}/port');
    // The runner ends a command after ten minutes at the most, so the
    // server outlives every remote run the gate makes and nothing else.
    final running = runtime.exec('python', [
      script.path,
      servedPath,
      portFile.path,
      credentials.path,
    ], timeout: const Duration(minutes: 10));
    unawaited(
      running.then((result) {
        final value = result.valueOrNull;
        debugPrint(
          'git gate server: ended ${value?.failure?.name ?? 'exit'} '
          '${value?.exitCode} ${value?.stderr.trim() ?? result}',
        );
      }),
    );
    int? port;
    final deadline = Stopwatch()..start();
    while (port == null && deadline.elapsed < const Duration(seconds: 90)) {
      if (portFile.existsSync()) {
        port = int.tryParse(portFile.readAsStringSync().trim());
      }
      if (port == null) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    expect(port, isNotNull, reason: 'the local git server did not listen');
    return GitRemoteServer._(
      runtime,
      folder.path,
      port: port!,
      url: 'http://127.0.0.1:$port/repo.git',
      user: user,
      token: token,
      startMs: watch.elapsedMilliseconds,
      running: running,
    );
  }

  final RuntimeService _runtime;
  final Future<Result<ExecResult>> _running;

  /// Where the server's own files live, in the runtime's home.
  final String folder;
  final int port;

  /// What the clone dialog is given.
  final String url;
  final String user;
  final String token;

  /// How long the repository and the server took to come up.
  final int startMs;

  /// The host as the credential dialog names it.
  String get host => '127.0.0.1:$port';

  String get _bare => '$folder/served/repo.git';

  /// Somebody else's working copy of the same repository, cloned straight
  /// from the bare one (no HTTP, so no token): the gate commits there to
  /// make the pull that the app must merge.
  Future<String> otherWorkingCopy() async {
    final path = '$folder/other';
    if (!Directory(path).existsSync()) {
      await gitOk(_runtime, folder, ['clone', '-q', _bare, 'other']);
    }
    return path;
  }

  /// Commits [text] as [path] in the other working copy and pushes it, so
  /// the app's next pull brings it down.
  Future<void> commitElsewhere(
    String path,
    String text, {
    required String message,
  }) async {
    final work = await otherWorkingCopy();
    await gitOk(_runtime, work, ['pull', '-q', '--ff-only']);
    File('$work/$path')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    await gitOk(_runtime, work, ['add', '-A']);
    await gitOk(_runtime, work, ['commit', '-q', '-m', message]);
    await gitOk(_runtime, work, ['push', '-q', 'origin', 'main']);
  }

  /// A line of `git log` in the bare repository the server serves: what
  /// the device's push actually left on the other side.
  Future<String> servedLog(String format, {String revision = 'main'}) async {
    final shown = await gitOk(_runtime, _bare, [
      'log',
      '-1',
      '--format=$format',
      revision,
    ]);
    return shown.stdout.trim();
  }

  /// [path] as the bare repository has it on [revision].
  Future<String> servedFile(String path, {String revision = 'main'}) async {
    final shown = await gitOk(_runtime, _bare, ['show', '$revision:$path']);
    return shown.stdout;
  }

  /// Stops the server and takes the token's file away. The repository
  /// itself stays for the evidence the gate collects afterwards.
  Future<void> stop() async {
    // The brackets keep pkill's own command line out of the match.
    await _runtime.exec('pkill', [
      '-f',
      '[c]odeforge-git-gate-server.py',
    ], timeout: const Duration(seconds: 60));
    final credentials = File('$folder/credentials');
    if (credentials.existsSync()) {
      credentials.deleteSync();
    }
    await _running.timeout(
      const Duration(seconds: 90),
      onTimeout: () => const Ok(ExecResult()),
    );
  }
}

/// Writes a repository of [files] files under [root], in folders of
/// [filesPerFolder]; how long the writing took, in milliseconds.
int writeLargeRepository(String root, {int files = largeFileCount}) {
  final watch = Stopwatch()..start();
  final folders = files ~/ filesPerFolder;
  for (var folder = 0; folder < folders; folder++) {
    final name = 'd${folder.toString().padLeft(4, '0')}';
    Directory('$root/$name').createSync(recursive: true);
    for (var file = 0; file < filesPerFolder; file++) {
      File(
        '$root/$name/f${file.toString().padLeft(2, '0')}.txt',
      ).writeAsStringSync('folder $folder, file $file\n');
    }
  }
  return watch.elapsedMilliseconds;
}

/// What a run of statuses took, as the user waits for them.
final class StatusFigures {
  StatusFigures(this.label, List<double> samples, {required this.files})
    : count = samples.length,
      p50Ms = _round1(percentile(samples, 0.5)),
      p95Ms = _round1(percentile(samples, 0.95)),
      maxMs = _round1(samples.fold<double>(0, math.max)),
      minMs = _round1(
        samples.isEmpty ? 0 : samples.reduce(math.min),
      );

  final String label;

  /// The files the repository holds, changed or not.
  final int files;
  final int count;
  final double p50Ms;
  final double p95Ms;
  final double maxMs;
  final double minMs;

  bool get underBudget => count > 0 && p95Ms <= statusBudgetMs;

  Map<String, Object?> toJson() => {
    'label': label,
    'files': files,
    'samples': count,
    'p50Ms': p50Ms,
    'p95Ms': p95Ms,
    'maxMs': maxMs,
    'minMs': minMs,
    'budgetMs': statusBudgetMs,
    'underBudget': underBudget,
  };

  String line() =>
      'status_$label files=$files n=$count p50_ms=$p50Ms p95_ms=$p95Ms '
      'max_ms=$maxMs min_ms=$minMs under_budget=${underBudget ? 1 : 0}';
}

/// [statusSamples] statuses of the open repository, each timed from the
/// panel's own refresh to the frame that draws what it found.
Future<StatusFigures> measureStatuses(
  WidgetTester tester,
  ProviderContainer container,
  String label, {
  required int files,
  int samples = statusSamples,
}) async {
  final git = container.read(gitControllerProvider.notifier);
  final times = <double>[];
  // One warm-up: the first status of a repository pays for the folder's
  // pages being read, which the ones the user sees do not.
  await git.refresh();
  await tester.pump();
  for (var i = 0; i < samples; i++) {
    final watch = Stopwatch()..start();
    await git.refresh();
    await tester.pump();
    times.add(watch.elapsedMicroseconds / 1000);
  }
  return StatusFigures(label, times, files: files);
}

/// Flutter's frames while [work] runs, with a progress bar laid over the
/// app so that every frame is asked for (terminal_measure.dart's rule:
/// at most 5 % over 32 ms, and none frozen).
Future<(T, UiFrames)> measureFrames<T>(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  Future<T> Function() work,
) => withFramesDrawn<T>(tester, binding, () async {
  final from = Timeline.now;
  final result = await work();
  return (result, from, Timeline.now);
});

/// The app driven as a finger drives it, for the Git work both targets
/// do: the emulator gate's git group (git_test.dart) and Test Lab's phone
/// (phone_git_test.dart). Nothing here settles the app — the panel's
/// spinner and the progress dialog's bar draw for as long as git runs, so
/// `pumpAndSettle` would never return — and nothing here reaches past the
/// screen: every step is a tap, a word typed, or a wait for what the
/// panel then shows.
final class GitDriver {
  GitDriver(this.tester, this.container, {required this.projectsRoot});

  /// A driver with the projects folder read once.
  static Future<GitDriver> of(
    WidgetTester tester,
    ProviderContainer container,
  ) async =>
      GitDriver(tester, container, projectsRoot: await projectsRootPath());

  final WidgetTester tester;
  final ProviderContainer container;

  /// Where the app keeps its projects (`<files>/workspaces`).
  final String projectsRoot;

  /// What the Git panel knows, and the controller behind it.
  GitRepoState get repo => container.read(gitControllerProvider);
  GitController get control => container.read(gitControllerProvider.notifier);

  /// Whether anything [key] names is on screen.
  bool shown(String key) => find.byKey(ValueKey(key)).evaluate().isNotEmpty;

  /// Taps what [key] names, scrolled into view first.
  Future<void> tap(String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 150));
  }

  /// Taps the one button that reads [text]: an empty state's action has
  /// no key of its own.
  Future<void> tapText(String text) async {
    await tester.tap(find.text(text));
    await tester.pump(const Duration(milliseconds: 150));
  }

  /// Types [text] into the field [key] names.
  Future<void> type(String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
    await tester.pump(const Duration(milliseconds: 150));
  }

  Future<void> waitFor(
    String key, {
    Duration timeout = const Duration(seconds: 60),
  }) => pumpUntil(
    tester,
    () => shown(key),
    what: 'the $key to be on screen',
    timeout: timeout,
  );

  Future<void> waitGone(
    String key, {
    Duration timeout = const Duration(minutes: 5),
  }) => pumpUntil(
    tester,
    () => !shown(key),
    what: 'the $key to go',
    timeout: timeout,
  );

  /// Opens the Git panel: a sheet on a phone, the sidebar on a tablet.
  Future<void> openPanel() async {
    if (!shown('git_panel')) {
      await tap('activity_git');
      // The sheet's own animation, which nothing else waits for.
      await tester.pump(const Duration(milliseconds: 400));
      await waitFor('git_panel');
    }
  }

  /// Closes the panel's sheet, where there is one.
  Future<void> closePanel() async {
    if (shown('git_panel') && shown('activity_git')) {
      await tap('activity_git');
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  /// Waits for a status that satisfies [ready], with none still running.
  Future<void> statusWhere(
    bool Function(GitStatus status) ready, {
    required String what,
    Duration timeout = const Duration(minutes: 3),
  }) => pumpUntil(
    tester,
    () {
      final seen = repo.status;
      return seen != null && !repo.refreshing && ready(seen);
    },
    what: what,
    timeout: timeout,
  );

  /// Makes a project, opens it, waits for the Git panel to follow it, and
  /// answers its folder on disk.
  Future<String> openProject(String name) async {
    final switcher = container.read(workspaceSwitcherProvider);
    final made = await switcher.createProject(name);
    final project = made.valueOrNull;
    expect(project, isNotNull, reason: 'create $name: $made');
    final opened = await switcher.open(project!);
    expect(opened.isOk, isTrue, reason: 'open $name: $opened');
    await pumpUntil(
      tester,
      () => repo.project == project.folder,
      what: 'the Git panel to follow $name',
    );
    return '$projectsRoot/${project.folder}';
  }

  /// Stages everything and commits [message] through the commit box, as
  /// the user does: *Stage all*, the message, *Commit*.
  Future<void> commitEverything(
    String message, {
    Duration timeout = const Duration(minutes: 8),
  }) async {
    await openPanel();
    await waitFor('git_stage_all');
    await tap('git_stage_all');
    await statusWhere(
      (status) => status.staged.isNotEmpty && status.unstaged.isEmpty,
      what: 'the changes to be staged',
      timeout: timeout,
    );
    await type('git_commit_message', message);
    expect(
      shown('git_commit_problem'),
      isFalse,
      reason: 'the commit box is ready',
    );
    await tap('git_commit');
    await statusWhere(
      (status) => status.staged.isEmpty,
      what: 'the commit to be made',
      timeout: timeout,
    );
  }
}

/// Where a token was found, if anywhere (Phase 7 W6: nowhere).
final class SecretSweep {
  SecretSweep({
    required this.files,
    required this.filesRead,
    required this.processes,
    required this.processesRead,
    required this.sweeps,
    required this.gitSeen,
  });

  /// The files that hold the token: none, or the gate fails.
  final List<String> files;

  /// How many files were read looking for it.
  final int filesRead;

  /// `<pid> cmdline` or `<pid> environ` for every process that holds it.
  final List<String> processes;
  final int processesRead;

  /// How many times the processes were looked through, and how often one
  /// of git's own was among them: a sweep that saw none proves nothing.
  final int sweeps;
  final int gitSeen;

  bool get clean => files.isEmpty && processes.isEmpty;

  Map<String, Object?> toJson() => {
    'files': files,
    'filesRead': filesRead,
    'processes': processes,
    'processesRead': processesRead,
    'sweeps': sweeps,
    'gitSeen': gitSeen,
    'clean': clean,
  };

  String line() =>
      'secret files=${files.length} files_read=$filesRead '
      'processes=${processes.length} processes_read=$processesRead '
      'sweeps=$sweeps git_seen=$gitSeen clean=${clean ? 1 : 0}';
}

/// Files over this are not read: a token is a short line, and a pack file
/// is not where one hides.
const int _maxScannedBytes = 4 * 1024 * 1024;

/// Every regular file under [roots] that holds [secret], as a path.
Future<List<String>> _filesHolding(
  List<String> roots,
  String secret, {
  required void Function(int read) counted,
}) async {
  final needle = utf8.encode(secret);
  final found = <String>[];
  var read = 0;
  for (final root in roots) {
    final directory = Directory(root);
    if (!directory.existsSync()) {
      continue;
    }
    final entities = directory
        .list(recursive: true, followLinks: false)
        .handleError((Object _) {});
    await for (final entity in entities) {
      if (entity is! File) {
        continue;
      }
      try {
        // Sync for the size (avoid_slow_async_io), async for the bytes.
        final length = entity.lengthSync();
        if (length == 0 || length > _maxScannedBytes) {
          continue;
        }
        read += 1;
        final bytes = await entity.readAsBytes();
        if (_holds(bytes, needle)) {
          found.add(entity.path);
        }
      } on FileSystemException {
        // A file the app may not read, or one that went away meanwhile.
        continue;
      }
    }
  }
  counted(read);
  return found;
}

bool _holds(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) {
    return false;
  }
  outer:
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    for (var index = 0; index < needle.length; index++) {
      if (haystack[start + index] != needle[index]) {
        continue outer;
      }
    }
    return true;
  }
  return false;
}

/// Looks through every process this app can see for [secret] in its
/// arguments or its environment: git's own children run as the app, so
/// what they were given is readable here.
Future<({List<String> found, int read, bool git})> sweepProcesses(
  String secret,
) async {
  final needle = utf8.encode(secret);
  final found = <String>[];
  var read = 0;
  var git = false;
  final processes = Directory('/proc');
  if (!processes.existsSync()) {
    return (found: found, read: read, git: git);
  }
  for (final entity in processes.listSync(followLinks: false)) {
    final pid = int.tryParse(entity.path.split('/').last);
    if (pid == null) {
      continue;
    }
    for (final what in const ['cmdline', 'environ']) {
      try {
        final bytes = await File('${entity.path}/$what').readAsBytes();
        if (bytes.isEmpty) {
          continue;
        }
        read += 1;
        if (what == 'cmdline') {
          final line = utf8.decode(bytes, allowMalformed: true);
          if (line.contains('git') || line.contains('http-backend')) {
            git = true;
          }
        }
        if (_holds(bytes, needle)) {
          found.add('$pid $what');
        }
      } on FileSystemException {
        // Another app's process, or one that exited while it was read.
        continue;
      }
    }
  }
  return (found: found, read: read, git: git);
}

/// Looks for [secret] while [work] runs — the processes, again and again,
/// for as long as it takes — and then in the files [roots] hold.
Future<(T, SecretSweep)> sweepWhile<T>(
  String secret,
  List<String> roots,
  Future<T> Function() work,
) async {
  final processes = <String>[];
  var sweeps = 0;
  var processesRead = 0;
  var gitSeen = 0;
  var running = true;
  Future<void> sweep() async {
    while (running) {
      final seen = await sweepProcesses(secret);
      sweeps += 1;
      processesRead += seen.read;
      if (seen.git) {
        gitSeen += 1;
      }
      processes.addAll(seen.found);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  final sweeping = sweep();
  final T result;
  try {
    result = await work();
  } finally {
    running = false;
    await sweeping;
  }
  var filesRead = 0;
  final files = await _filesHolding(
    roots,
    secret,
    counted: (read) => filesRead = read,
  );
  return (
    result,
    SecretSweep(
      files: files,
      filesRead: filesRead,
      processes: processes,
      processesRead: processesRead,
      sweeps: sweeps,
      gitSeen: gitSeen,
    ),
  );
}
