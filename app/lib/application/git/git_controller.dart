/// The open project's repository (Phase 7 W2, PHASE_7_PLAN W2;
/// docs/GIT_ARCHITECTURE.md): its status for the status strip and, from
/// W4, the Source control panel, and the operations that change it.
///
/// - **Refreshed** after each operation made through it, after a save (an
///   open document's stamp changes; typing does not), on the watcher's
///   batches, on changes in the project's `.git` folder (so the terminal's
///   git shows too), and when the app comes back to the foreground.
/// - **Debounced:** changes gather for [GitSettings.debounce]. One status
///   runs at a time; a change that comes while one runs starts another
///   after it, so the newest state is the one that stays.
/// - **Changes queue:** the host runs one change at a time per repository
///   and refuses a second as busy, so operations wait for each other here.
/// - **In the background** nothing runs; coming back refreshes.
/// - **A folder from shared storage** has no Git: Git works in projects
///   (PHASE_7_PLAN §10, decision (a)); W4 offers to import it as one.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/files/workspace_location.dart';
import '../../core/git/git_models.dart';
import '../../core/logging/logger.dart';
import '../../services/contracts.dart';
import '../../services/runtime/runtime_service.dart';
import '../documents/document_controller.dart';
import '../documents/document_state.dart';
import '../providers.dart';
import '../runtime_controller.dart';

/// How the controller paces itself.
final class GitSettings {
  const GitSettings({
    this.debounce = const Duration(milliseconds: 300),
    this.maxFiles,
  });

  /// How long changes gather before a status runs.
  final Duration debounce;

  /// The most files a status lists; the service's default when null.
  final int? maxFiles;
}

final gitSettingsProvider = Provider<GitSettings>(
  (ref) => const GitSettings(),
);

/// What the workspace is to Git.
enum GitRepoKind {
  /// No git here: no host (`flutter test`), or the runtime cannot run it.
  unavailable,

  /// A folder from shared storage: Git works in projects only.
  folder,

  /// The Linux runtime is not ready yet.
  waiting,

  /// The first status runs.
  loading,

  /// The project is not a repository.
  notARepository,

  /// A repository: [GitRepoState.status] says how it is.
  repository,

  /// The last status failed: [GitRepoState.failure] says why, and
  /// [GitRepoState.status] is the one before, if any.
  failed,
}

final class GitRepoState {
  const GitRepoState({
    this.kind = GitRepoKind.unavailable,
    this.project,
    this.status,
    this.failure,
    this.refreshing = false,
    this.changing = false,
  });

  final GitRepoKind kind;

  /// The project's folder name.
  final String? project;

  /// The last status read.
  final GitStatus? status;

  final GitFailure? failure;

  /// A status runs.
  final bool refreshing;

  /// An operation runs or waits.
  final bool changing;

  GitRepoState copyWith({bool? refreshing, bool? changing}) => GitRepoState(
    kind: kind,
    project: project,
    status: status,
    failure: failure,
    refreshing: refreshing ?? this.refreshing,
    changing: changing ?? this.changing,
  );
}

final gitControllerProvider = NotifierProvider<GitController, GitRepoState>(
  GitController.new,
);

final class GitController extends Notifier<GitRepoState> {
  GitService? _service;
  GitSettings _settings = const GitSettings();
  String? _project;

  /// Whether this build may run git at all.
  bool _canRun = false;
  bool _foreground = true;
  Timer? _debounce;

  /// The status that runs, and whether another must follow it.
  Completer<void>? _running;
  bool _again = false;

  /// The tail of the queue of changes, and how many wait or run.
  Future<void> _changes = Future<void>.value();
  int _queued = 0;

  StreamSubscription<void>? _gitFolder;

  /// Grows with every build: what an older build started is stale.
  int _build = 0;

  @override
  GitRepoState build() {
    final service = ref.watch(gitServiceProvider);
    final settings = ref.watch(gitSettingsProvider);
    final location = ref.watch(currentWorkspaceProvider);
    final runtimeReady = ref.watch(
      runtimeControllerProvider.select((s) => s.state == RuntimeState.ready),
    );
    _build += 1;
    final build = _build;
    _service = service;
    _settings = settings;
    _running = null;
    _again = false;
    _changes = Future<void>.value();
    _queued = 0;
    final project = switch (location) {
      ProjectLocation(:final folder) => folder,
      FolderLocation() => null,
    };
    _project = project;
    _canRun = service.available && project != null && runtimeReady;
    ref.onDispose(() {
      _build += 1;
      _canRun = false;
      _debounce?.cancel();
      _debounce = null;
      _unwatchGitFolder();
    });
    if (!service.available) {
      return const GitRepoState();
    }
    if (project == null) {
      return const GitRepoState(kind: GitRepoKind.folder);
    }
    if (!runtimeReady) {
      return GitRepoState(kind: GitRepoKind.waiting, project: project);
    }
    // A save changes an open document's stamp; typing does not.
    ref.listen<int>(
      documentControllerProvider.select(_stampsOf),
      (previous, next) => changed(),
    );
    // The first status, once this build is the state.
    scheduleMicrotask(() {
      if (build == _build) {
        unawaited(_status(build));
      }
    });
    return GitRepoState(kind: GitRepoKind.loading, project: project);
  }

  /// Something may have changed: a status runs after the debounce.
  void changed() {
    if (!_canRun || !_foreground) {
      return;
    }
    _debounce?.cancel();
    final build = _build;
    _debounce = Timer(_settings.debounce, () {
      _debounce = null;
      unawaited(_status(build));
    });
  }

  /// A status now, or after the one that runs; done when the state shows
  /// the repository as it is now.
  Future<void> refresh() {
    _debounce?.cancel();
    _debounce = null;
    return _status(_build);
  }

  /// The app went to the background: nothing runs until it comes back.
  void paused() {
    _foreground = false;
    _debounce?.cancel();
    _debounce = null;
  }

  /// The app came back: what changed meanwhile shows now.
  Future<void> resumed() async {
    if (_foreground) {
      return;
    }
    _foreground = true;
    await refresh();
  }

  // The operations: each waits for the ones before it, then the status
  // refreshes before its result is given.

  Future<Result<void>> stage(List<String> paths) =>
      _change('stage', (git, project) => git.stage(project, paths));

  Future<Result<void>> stageAll() =>
      _change('stage_all', (git, project) => git.stageAll(project));

  Future<Result<void>> unstage(List<String> paths) =>
      _change('unstage', (git, project) => git.unstage(project, paths));

  Future<Result<void>> discard(List<String> paths) =>
      _change('discard', (git, project) => git.discard(project, paths));

  Future<Result<void>> deleteUntracked(List<String> paths) => _change(
    'delete_untracked',
    (git, project) => git.deleteUntracked(project, paths),
  );

  Future<Result<void>> commit(String message, {bool amend = false}) => _change(
    'commit',
    (git, project) => git.commit(project, message, amend: amend),
  );

  Future<Result<void>> createBranch(
    String name, {
    String? from,
    bool switchTo = true,
  }) => _change(
    'create_branch',
    (git, project) =>
        git.createBranch(project, name, from: from, switchTo: switchTo),
  );

  Future<Result<void>> switchBranch(
    String name, {
    void Function(GitProgress progress)? onProgress,
  }) => _change(
    'switch_branch',
    (git, project) => git.switchBranch(project, name, onProgress: onProgress),
  );

  Future<Result<void>> deleteBranch(String name, {bool force = false}) =>
      _change(
        'delete_branch',
        (git, project) => git.deleteBranch(project, name, force: force),
      );

  Future<Result<void>> merge(
    String branch, {
    void Function(GitProgress progress)? onProgress,
  }) => _change(
    'merge',
    (git, project) => git.merge(project, branch, onProgress: onProgress),
  );

  Future<Result<void>> abortMerge() =>
      _change('abort_merge', (git, project) => git.abortMerge(project));

  Future<Result<void>> init({String initialBranch = 'main'}) => _change(
    'init',
    (git, project) => git.init(project, initialBranch: initialBranch),
  );

  /// Runs [change] after the changes queued before it, then refreshes.
  Future<Result<void>> _change(
    String name,
    Future<Result<void>> Function(GitService git, String project) change,
  ) {
    final service = _service;
    final project = _project;
    if (!_canRun || service == null || project == null) {
      return Future.value(
        const Err<void>(
          GitFailure(
            'Git works in projects, once the Linux runtime is ready.',
            problem: GitProblem.unavailable,
          ),
        ),
      );
    }
    final build = _build;
    final done = Completer<Result<void>>();
    _queued += 1;
    state = state.copyWith(changing: true);
    _changes = _changes.then((_) async {
      Result<void> result;
      if (!ref.mounted || build != _build) {
        result = const Err<void>(
          GitFailure(
            'The workspace changed before Git could run.',
            problem: GitProblem.stopped,
          ),
        );
      } else {
        final started = DateTime.now();
        try {
          result = await change(service, project);
        } on Object catch (error) {
          result = Err<void>(
            GitFailure(
              'Git could not do that.',
              problem: GitProblem.unknown,
              cause: error,
            ),
          );
        }
        appLogger.info(
          'git',
          'operation',
          fields: {
            'op': name,
            'ok': result is Ok<void>,
            if (result case Err<void>(failure: GitFailure(:final problem)))
              'problem': problem.code,
            'ms': DateTime.now().difference(started).inMilliseconds,
          },
        );
        if (ref.mounted && build == _build) {
          await refresh();
        }
      }
      if (build == _build) {
        _queued -= 1;
        if (ref.mounted) {
          state = state.copyWith(changing: _queued > 0);
        }
      }
      done.complete(result);
    });
    return done.future;
  }

  Future<void> _status(int build) {
    if (!_canRun || build != _build) {
      return Future<void>.value();
    }
    final running = _running;
    if (running != null) {
      _again = true;
      return running.future;
    }
    final completer = Completer<void>();
    _running = completer;
    unawaited(_statusLoop(build, completer));
    return completer.future;
  }

  Future<void> _statusLoop(int build, Completer<void> completer) async {
    try {
      do {
        _again = false;
        if (!ref.mounted || build != _build) {
          return;
        }
        state = state.copyWith(refreshing: true);
        final result = await _service!.status(
          _project!,
          maxFiles: _settings.maxFiles,
        );
        if (!ref.mounted || build != _build) {
          return;
        }
        _apply(result);
      } while (_again && _foreground);
    } finally {
      if (identical(_running, completer)) {
        _running = null;
      }
      completer.complete();
    }
  }

  void _apply(Result<GitStatus> result) {
    final project = _project;
    final changing = state.changing;
    switch (result) {
      case Ok<GitStatus>(:final value):
        state = GitRepoState(
          kind: GitRepoKind.repository,
          project: project,
          status: value,
          changing: changing,
        );
        _watchGitFolder();
      case Err<GitStatus>(
        failure: GitFailure(problem: GitProblem.notARepository),
      ):
        state = GitRepoState(
          kind: GitRepoKind.notARepository,
          project: project,
          changing: changing,
        );
        _watchGitFolder();
      case Err<GitStatus>(failure: GitFailure(problem: GitProblem.notReady)):
        state = GitRepoState(kind: GitRepoKind.waiting, project: project);
      case Err<GitStatus>(
        failure: GitFailure(problem: GitProblem.unavailable),
      ):
        state = GitRepoState(kind: GitRepoKind.unavailable, project: project);
      case Err<GitStatus>(:final failure):
        final gitFailure = failure is GitFailure
            ? failure
            : GitFailure(
                failure.message,
                problem: GitProblem.unknown,
                cause: failure,
              );
        appLogger.info(
          'git',
          'status_failed',
          fields: {'problem': gitFailure.problem.code},
        );
        state = GitRepoState(
          kind: GitRepoKind.failed,
          project: project,
          status: state.status,
          failure: gitFailure,
          changing: changing,
        );
    }
  }

  /// Watches the project's `.git` folder, once there is one: the index,
  /// HEAD and the merge's files change there whoever runs git. A project
  /// without one is watched again after the next status.
  void _watchGitFolder() {
    if (_gitFolder != null) {
      return;
    }
    final build = _build;
    _gitFolder = ref
        .read(fileServiceProvider)
        .watchFolder('.git')
        .listen(
          (_) {
            if (build == _build) {
              changed();
            }
          },
          onError: (Object _) => _unwatchGitFolder(),
          onDone: () => _gitFolder = null,
        );
  }

  void _unwatchGitFolder() {
    unawaited(_gitFolder?.cancel());
    _gitFolder = null;
  }

  /// The open documents' stamps, as one number: it changes when a document
  /// is saved, opened or closed, never while typing.
  static int _stampsOf(DocumentsState documents) =>
      Object.hashAll([for (final doc in documents.documents.values) doc.stamp]);
}

/// The branch chip's words (Phase 7 W2): where the work tree is, what
/// changed, and how it stands with its upstream.
String gitBranchTooltip(GitRepoState git) {
  final status = git.status;
  if (status == null) {
    return git.failure?.message ?? 'Git';
  }
  final branch = status.branch;
  final parts = <String>[
    if (branch.detached)
      'HEAD detached at ${branch.label}'
    else if (branch.unborn)
      'On branch ${branch.label}, no commits yet'
    else
      'On branch ${branch.label}',
    _count(
      status.changeCount,
      'changed file',
      none: 'No changes',
      more: status.truncated,
    ),
    if (status.conflicted.isNotEmpty)
      _count(status.conflicted.length, 'conflicted file'),
    if (branch.upstream case final upstream?)
      switch ((branch.ahead, branch.behind)) {
        (0, 0) => 'Up to date with $upstream',
        (final int ahead, final int behind) =>
          '$ahead ahead of and $behind behind $upstream',
        _ => 'Tracking $upstream',
      },
    if (git.kind == GitRepoKind.failed && git.failure != null)
      git.failure!.message,
  ];
  return '${[for (final part in parts) part.endsWith('.') ? part.substring(0, part.length - 1) : part].join('. ')}.';
}

String _count(int n, String noun, {String? none, bool more = false}) {
  if (n == 0 && none != null) {
    return none;
  }
  final count = more ? 'More than $n' : '$n';
  return '$count $noun${n == 1 ? '' : 's'}';
}
