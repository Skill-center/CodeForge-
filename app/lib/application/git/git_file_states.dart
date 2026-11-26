/// What Git says about each file the explorer shows (Phase 7 W4,
/// PHASE_7_PLAN W4): a file is coloured by its own state, a folder by the
/// worst state among the files under it.
///
/// The map is made from the status the Git controller already read
/// (git_controller.dart), so the explorer asks git nothing of its own. A
/// status that the host truncated colours the files it did list; the rest
/// stay plain. Paths are the workspace's: relative to the project and
/// '/'-separated, as git gives them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/git/git_models.dart';
import 'git_controller.dart';

/// How a file stands with Git, worst first: a folder takes the first of
/// these that any file under it has.
enum GitFileState {
  conflicted('!', 'conflicted'),
  deleted('D', 'deleted'),
  modified('M', 'modified'),
  renamed('R', 'renamed'),
  added('A', 'added'),
  untracked('U', 'new');

  const GitFileState(this.letter, this.word);

  /// The letter the explorer draws after the name.
  final String letter;

  /// What TalkBack says after the name.
  final String word;

  /// Worse than [other]: earlier in this list.
  bool worseThan(GitFileState other) => index < other.index;
}

/// A file's state, or null when Git says nothing about it (unchanged,
/// ignored, or outside a repository).
GitFileState? gitFileStateOf(GitFileStatus file) {
  if (file.conflicted) {
    return GitFileState.conflicted;
  }
  if (file.untracked) {
    return GitFileState.untracked;
  }
  if (file.kind == GitEntryKind.ignored) {
    return null;
  }
  // The work tree first: what is on disk is what the explorer shows.
  final change = file.workTree != GitChange.unmodified
      ? file.workTree
      : file.index;
  return switch (change) {
    GitChange.unmodified => null,
    GitChange.deleted => GitFileState.deleted,
    GitChange.added => GitFileState.added,
    GitChange.renamed || GitChange.copied => GitFileState.renamed,
    GitChange.modified ||
    GitChange.typeChanged ||
    GitChange.unmerged => GitFileState.modified,
  };
}

/// Every path Git has something to say about, files and their folders.
final class GitFileStates {
  const GitFileStates._(this._files, this._folders);

  /// Nothing is coloured: no repository, or no status read yet.
  static const GitFileStates none = GitFileStates._(
    <String, GitFileState>{},
    <String, GitFileState>{},
  );

  factory GitFileStates.of(GitStatus status) {
    final files = <String, GitFileState>{};
    final folders = <String, GitFileState>{};
    for (final file in status.files) {
      final state = gitFileStateOf(file);
      if (state == null) {
        continue;
      }
      // A rename shows at both ends: where the file was, and where it is.
      final paths = <String>[file.path, ?file.originalPath];
      for (final path in paths) {
        final worst = files[path];
        if (worst == null || state.worseThan(worst)) {
          files[path] = state;
        }
        for (
          var slash = path.indexOf('/');
          slash > 0;
          slash = path.indexOf('/', slash + 1)
        ) {
          final folder = path.substring(0, slash);
          final held = folders[folder];
          if (held == null || state.worseThan(held)) {
            folders[folder] = state;
          }
        }
      }
    }
    return GitFileStates._(files, folders);
  }

  final Map<String, GitFileState> _files;
  final Map<String, GitFileState> _folders;

  bool get isEmpty => _files.isEmpty;

  /// [path]'s state: its own for a file, the worst under it for a folder.
  GitFileState? stateOf(String path, {bool isDirectory = false}) =>
      isDirectory ? _folders[path] : _files[path];
}

/// The states the explorer colours its rows by.
final gitFileStatesProvider = Provider<GitFileStates>((ref) {
  final kind = ref.watch(gitControllerProvider.select((git) => git.kind));
  final status = ref.watch(gitControllerProvider.select((git) => git.status));
  if (status == null ||
      (kind != GitRepoKind.repository && kind != GitRepoKind.failed)) {
    return GitFileStates.none;
  }
  return GitFileStates.of(status);
});
