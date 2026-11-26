/// What the Source control panel shows beyond the status (Phase 7 W4,
/// PHASE_7_PLAN W4; docs/GIT_ARCHITECTURE.md §3): the branches, the
/// history, the identity commits are made with, and the commit box the
/// user is typing in.
///
/// The status itself, and every operation that changes the repository,
/// belong to the Git controller (git_controller.dart); this one only
/// reads, and the host runs reads alongside a change. What it holds:
///
/// - **Sections** open and close, and a section reads what it shows the
///   first time it opens: nothing is read for a section nobody looked at.
/// - **A commit, a switch or a pull** changes the branch the status
///   reports, and that reloads whatever is open, so the branches and the
///   history follow without being asked. What the panel does itself to a
///   branch reloads them too ([reload]).
/// - **The commit box** keeps its message while the panel comes and goes
///   with the activity, and until a commit is made with it. Choosing
///   *Amend the last commit* with an empty box fills in that commit's
///   message, which the user may then change.
/// - **Why Commit cannot run** ([commitProblem]) is one sentence: a
///   conflict, nothing staged, no identity, or no message.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/git/git_errors.dart';
import '../../core/git/git_models.dart';
import '../../services/contracts.dart';
import '../providers.dart';
import 'git_controller.dart';

/// The panel's parts that open and close.
enum GitPanelSection {
  changes('Changes'),
  branches('Branches'),
  history('History');

  const GitPanelSection(this.title);

  final String title;
}

/// The newest commits the history reads at once.
const int gitHistoryLength = 100;

final class GitPanelState {
  const GitPanelState({
    this.open = const {GitPanelSection.changes},
    this.loaded = const {},
    this.loading = const {},
    this.branches = const [],
    this.history = const [],
    this.failures = const {},
    this.identity,
    this.message = '',
    this.amend = false,
  });

  /// The sections the user has open.
  final Set<GitPanelSection> open;

  /// The sections read since the last change to the branch.
  final Set<GitPanelSection> loaded;

  /// The sections reading now.
  final Set<GitPanelSection> loading;

  /// Local branches and the remotes', as the host lists them.
  final List<GitBranch> branches;

  /// The branch's newest commits, newest first.
  final List<GitCommit> history;

  /// Why a section could not be read.
  final Map<GitPanelSection, GitFailure> failures;

  /// The identity commits are made with; null until it has been read.
  final GitIdentity? identity;

  /// What is typed in the commit box.
  final String message;

  /// Commit replaces the last commit instead of making one.
  final bool amend;

  List<GitBranch> get localBranches => [
    for (final branch in branches)
      if (branch.kind == GitBranchKind.local) branch,
  ];

  bool isOpen(GitPanelSection section) => open.contains(section);

  bool isLoading(GitPanelSection section) => loading.contains(section);

  GitPanelState copyWith({
    Set<GitPanelSection>? open,
    Set<GitPanelSection>? loaded,
    Set<GitPanelSection>? loading,
    List<GitBranch>? branches,
    List<GitCommit>? history,
    Map<GitPanelSection, GitFailure>? failures,
    GitIdentity? identity,
    String? message,
    bool? amend,
  }) => GitPanelState(
    open: open ?? this.open,
    loaded: loaded ?? this.loaded,
    loading: loading ?? this.loading,
    branches: branches ?? this.branches,
    history: history ?? this.history,
    failures: failures ?? this.failures,
    identity: identity ?? this.identity,
    message: message ?? this.message,
    amend: amend ?? this.amend,
  );
}

/// Why the commit box cannot commit now, in one sentence; null when it
/// can. The panel says it instead of letting the commit fail.
String? commitProblem(GitRepoState git, GitPanelState panel) {
  final status = git.status;
  if (status == null) {
    return 'Git has not read this repository yet.';
  }
  if (status.conflicted.isNotEmpty) {
    return gitProblemMessage(GitProblem.conflict);
  }
  if (panel.amend) {
    if (status.branch.unborn) {
      return gitProblemMessage(GitProblem.noCommits);
    }
  } else if (status.staged.isEmpty) {
    return 'Stage something to commit.';
  }
  final identity = panel.identity;
  if (identity != null && !identity.complete) {
    return gitProblemMessage(GitProblem.noIdentity);
  }
  // Amending with an empty box keeps the last commit's message.
  if (!panel.amend && panel.message.trim().isEmpty) {
    return 'Write a message for the commit.';
  }
  return null;
}

final gitPanelControllerProvider =
    NotifierProvider<GitPanelController, GitPanelState>(GitPanelController.new);

final class GitPanelController extends Notifier<GitPanelState> {
  GitService? _service;
  String? _project;

  /// Grows with every build and every reload: what an older read answers
  /// is stale.
  int _generation = 0;

  @override
  GitPanelState build() {
    final service = ref.watch(gitServiceProvider);
    final git = ref.read(gitControllerProvider);
    _service = service;
    _project = git.project;
    _generation += 1;
    // The branch the status reports changes with every commit, switch,
    // pull or fetch, whoever ran it — the terminal's git included.
    ref.listen<GitBranchState?>(
      gitControllerProvider.select((git) => git.status?.branch),
      (previous, next) => reload(),
    );
    ref.listen<GitRepoKind>(
      gitControllerProvider.select((git) => git.kind),
      (previous, next) => reload(),
    );
    if (_readable) {
      scheduleMicrotask(_readIdentity);
    }
    return const GitPanelState();
  }

  /// There is a repository here and a host to read it with.
  bool get _readable {
    final service = _service;
    final kind = ref.read(gitControllerProvider).kind;
    return service != null &&
        service.available &&
        _project != null &&
        (kind == GitRepoKind.repository || kind == GitRepoKind.failed);
  }

  /// Reads every open section again, from whatever the repository is now.
  void reload() {
    _generation += 1;
    _project = ref.read(gitControllerProvider).project;
    state = state.copyWith(loaded: const {}, loading: const {});
    for (final section in state.open) {
      unawaited(load(section));
    }
    if (state.identity == null) {
      scheduleMicrotask(_readIdentity);
    }
  }

  /// Opens or closes [section]; opening reads it when it is stale.
  void toggle(GitPanelSection section) {
    final open = {...state.open};
    if (!open.remove(section)) {
      open.add(section);
    }
    state = state.copyWith(open: open);
    if (open.contains(section)) {
      unawaited(load(section));
    }
  }

  /// Reads [section] unless it is read already or reading now.
  Future<void> load(GitPanelSection section) async {
    if (section == GitPanelSection.changes ||
        state.loading.contains(section) ||
        state.loaded.contains(section) ||
        !_readable) {
      return;
    }
    final generation = _generation;
    state = state.copyWith(loading: {...state.loading, section});
    switch (section) {
      case GitPanelSection.branches:
        final result = await _service!.branches(_project!);
        if (!ref.mounted || generation != _generation) {
          return;
        }
        switch (result) {
          case Ok<List<GitBranch>>(:final value):
            _read(section, branches: value);
          case Err<List<GitBranch>>(:final failure):
            _read(section, failure: failure);
        }
      case GitPanelSection.history:
        final result = await _service!.log(_project!, max: gitHistoryLength);
        if (!ref.mounted || generation != _generation) {
          return;
        }
        switch (result) {
          case Ok<List<GitCommit>>(:final value):
            _read(section, history: value);
          case Err<List<GitCommit>>(:final failure):
            _read(section, failure: failure);
        }
      case GitPanelSection.changes:
        return;
    }
  }

  void _read(
    GitPanelSection section, {
    List<GitBranch>? branches,
    List<GitCommit>? history,
    Failure? failure,
  }) {
    final failures = {...state.failures}..remove(section);
    state = state.copyWith(
      loading: {...state.loading}..remove(section),
      loaded: {...state.loaded, section},
      branches: branches,
      history: history,
      failures: failure == null
          ? failures
          : {...failures, section: _gitFailure(failure)},
    );
  }

  Future<void> _readIdentity() async {
    if (!_readable) {
      return;
    }
    final generation = _generation;
    final result = await _service!.identity();
    if (!ref.mounted || generation != _generation) {
      return;
    }
    // An identity that cannot be read is not one that is missing: the
    // panel stays quiet, and a commit says what went wrong.
    if (result case Ok<GitIdentity>(:final value)) {
      state = state.copyWith(identity: value);
    }
  }

  /// The files [commit] changed, for the history's commit sheet.
  Future<Result<List<GitCommitFile>>> commitFiles(String commit) {
    if (!_readable) {
      return Future.value(
        const Err<List<GitCommitFile>>(
          GitFailure(
            'Git is not ready yet.',
            problem: GitProblem.notReady,
            operation: 'commit_files',
          ),
        ),
      );
    }
    return _service!.commitFiles(_project!, commit);
  }

  void setMessage(String message) {
    if (message != state.message) {
      state = state.copyWith(message: message);
    }
  }

  /// Chooses or leaves *Amend the last commit*; choosing it with an empty
  /// box fills in the last commit's message.
  Future<void> setAmend(bool amend) async {
    state = state.copyWith(amend: amend);
    if (!amend || state.message.trim().isNotEmpty || !_readable) {
      return;
    }
    final generation = _generation;
    final last = await _service!.log(_project!, max: 1);
    if (!ref.mounted || generation != _generation || !state.amend) {
      return;
    }
    if (last case Ok<List<GitCommit>>(value: [final commit, ...])) {
      if (state.message.trim().isEmpty) {
        state = state.copyWith(message: commit.subject);
      }
    }
  }

  /// Commits what is staged; on success the box is emptied and *Amend* is
  /// left behind.
  Future<Result<void>> commit() async {
    final result = await ref
        .read(gitControllerProvider.notifier)
        .commit(state.message.trim(), amend: state.amend);
    if (ref.mounted && result.isOk) {
      state = state.copyWith(message: '', amend: false);
    }
    return result;
  }

  GitFailure _gitFailure(Failure failure) => failure is GitFailure
      ? failure
      : GitFailure(failure.message, problem: GitProblem.unknown, cause: failure);
}
