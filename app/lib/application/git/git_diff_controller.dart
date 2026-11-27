/// Showing a file's changes in the editor (Phase 7 W5, PHASE_7_PLAN W5;
/// docs/EDITOR_ARCHITECTURE.md §11, docs/GIT_ARCHITECTURE.md §3.4).
///
/// Git has the older text; the editor draws the comparison. This is the
/// piece between them: it reads the right revision for what the user
/// tapped and hands both texts to the documents controller.
///
/// - **A changed file** opens as itself, editable, against what it is
///   being compared with: the staged version while its changes are
///   unstaged, the last commit once they are staged. Everything the diff
///   offers is an edit of the document — *Revert this change* included —
///   so Undo takes it back and Save writes it.
/// - **A file in a commit** opens as that commit left it, read-only, in a
///   tab of its own, against the commit before it. Two columns where
///   there is room for them, one on a narrow screen.
/// - **A new file** has nothing to compare with, so it is shown against
///   nothing: every line is an addition.
/// - **Too large** ([maxDiffChars], the size the editor opens as plain
///   text at) is not compared: the file still opens, and the pane says
///   why there is no comparison.
///
/// The read runs while the file is already open, so tapping a row shows
/// the file at once and the comparison a moment later. Paths being read
/// are in [GitDiffState.loading], which the panel shows.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/git/git_models.dart';
import '../../services/contracts.dart';
import '../documents/document_controller.dart';
import '../providers.dart';
import 'git_controller.dart';

/// What a comparison is called in the pane's banner.
const String againstStaged = 'the staged version';
const String againstHead = 'the last commit';
const String againstParent = 'the commit before it';
const String againstNothing = 'nothing: it is new';

final class GitDiffState {
  const GitDiffState({this.loading = const {}});

  /// The paths whose older text is being read now.
  final Set<String> loading;

  bool isLoading(String path) => loading.contains(path);
}

final gitDiffControllerProvider =
    NotifierProvider<GitDiffController, GitDiffState>(GitDiffController.new);

final class GitDiffController extends Notifier<GitDiffState> {
  GitService? _service;
  String? _project;

  @override
  GitDiffState build() {
    _service = ref.watch(gitServiceProvider);
    _project = ref.watch(gitControllerProvider.select((git) => git.project));
    return const GitDiffState();
  }

  DocumentController get _documents =>
      ref.read(documentControllerProvider.notifier);

  /// Opens [file] and shows what changed in it. The file opens even when
  /// the comparison cannot be read; the failure is returned either way,
  /// for the panel to say.
  Future<Result<void>> showChanges(GitFileStatus file) async {
    final service = _service;
    final project = _project;
    if (service == null || !service.available || project == null) {
      return const Err(
        GitFailure(
          'Git runs on the Linux runtime, on Android.',
          problem: GitProblem.unavailable,
        ),
      );
    }
    if (file.kind == GitEntryKind.tracked &&
        file.workTree == GitChange.deleted) {
      return Err(
        FileFailure(
          '${file.path} was deleted, so there is nothing to show here. '
          'Open the commit it was last in to read it.',
          problem: FileProblem.notFound,
        ),
      );
    }
    final opened = await _documents.open(file.path);
    if (opened case Err<void>(:final failure)) {
      return Err(failure);
    }
    // A file git does not track yet has no older version at all.
    if (file.untracked) {
      return _documents.showDiff(
        file.path,
        original: '',
        against: againstNothing,
      );
    }
    // Unstaged changes are against what is staged; once everything is
    // staged, the comparison that matters is with the last commit.
    final staged = !file.unstaged && !file.conflicted;
    final revision = staged ? 'HEAD' : null;
    final against = staged ? againstHead : againstStaged;
    // A file added in the index is in no commit yet.
    if (staged && file.index == GitChange.added) {
      return _documents.showDiff(
        file.path,
        original: '',
        against: againstNothing,
      );
    }
    // A rename's older text is at the name it had.
    final from = staged ? file.originalPath ?? file.path : file.path;
    final older = await _read(service, project, from, revision, file.path);
    switch (older) {
      case Err<String>(:final failure):
        return Err(failure);
      case Ok<String>(:final value):
        return _documents.showDiff(
          file.path,
          original: value,
          against: against,
        );
    }
  }

  /// Opens [file] as [commit] left it, read-only, against the commit
  /// before it. [wide] asks for two columns, which only fit where there
  /// is room.
  Future<Result<void>> showCommitFile(
    GitCommit commit,
    GitCommitFile file, {
    required bool wide,
  }) async {
    final service = _service;
    final project = _project;
    if (service == null || !service.available || project == null) {
      return const Err(
        GitFailure(
          'Git runs on the Linux runtime, on Android.',
          problem: GitProblem.unavailable,
        ),
      );
    }
    // A file this commit deleted is empty in it; one it added, and
    // anything in a root commit, has nothing before it.
    final gone = file.change == GitChange.deleted;
    final born = file.change == GitChange.added || commit.parents.isEmpty;
    final String text;
    if (gone) {
      text = '';
    } else {
      final newer = await _read(
        service,
        project,
        file.path,
        commit.hash,
        file.path,
      );
      switch (newer) {
        case Err<String>(:final failure):
          return Err(failure);
        case Ok<String>(:final value):
          text = value;
      }
    }
    final String original;
    if (born) {
      original = '';
    } else {
      final older = await _read(
        service,
        project,
        file.originalPath ?? file.path,
        '${commit.hash}^',
        file.path,
      );
      switch (older) {
        case Err<String>(:final failure):
          return Err(failure);
        case Ok<String>(:final value):
          original = value;
      }
    }
    return _documents.openRevision(
      filePath: file.path,
      revision: commit.hash,
      label: commit.shortHash,
      text: text,
      original: original,
      against: born ? againstNothing : againstParent,
      wide: wide,
    );
  }

  /// Reads [path] at [revision], with [shown] (the path the user tapped)
  /// marked as loading meanwhile.
  Future<Result<String>> _read(
    GitService service,
    String project,
    String path,
    String? revision,
    String shown,
  ) async {
    state = GitDiffState(loading: {...state.loading, shown});
    try {
      return await service.fileAt(project, path, revision: revision);
    } finally {
      if (ref.mounted) {
        state = GitDiffState(
          loading: {...state.loading.where((p) => p != shown)},
        );
      }
    }
  }
}
