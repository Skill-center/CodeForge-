/// What a failed git command means (Phase 7 W2, PHASE_7_PLAN W2): git's
/// exit code and its words, read into a [GitProblem].
///
/// git runs with `LANG=C.UTF-8` (runtime/RuntimeEnvironment.kt), so its
/// words are its own English ones, which have stayed the same across many
/// versions; each pattern below is checked against git's real output in
/// test/fixtures/git/errors.json. Some outcomes are said on stdout, not
/// stderr: `nothing to commit`, and a merge's `CONFLICT` lines.
library;

import '../errors/failure.dart';

/// [exitCode], [stderr] and [stdout]'s records read into what went wrong;
/// [GitProblem.gitError] when nothing below matches.
GitProblem classifyGitError({
  required int exitCode,
  required String stderr,
  List<String> stdout = const [],
}) {
  final err = stderr.toLowerCase();
  final out = stdout.join('\n').toLowerCase();
  bool said(String words) => err.contains(words);

  if (said('not a git repository')) {
    return GitProblem.notARepository;
  }
  if (said('index.lock') && said('file exists')) {
    return GitProblem.locked;
  }
  if (said('author identity unknown') ||
      said('please tell me who you are') ||
      said('unable to auto-detect email address') ||
      said('empty ident name') ||
      said('no email was given') ||
      said('no name was given')) {
    return GitProblem.noIdentity;
  }
  if (out.contains('conflict (') ||
      out.contains('automatic merge failed') ||
      said('conflict (')) {
    return GitProblem.conflict;
  }
  if (said('would be overwritten by')) {
    return GitProblem.localChanges;
  }
  if (said('you have not concluded your merge') ||
      said('merging is not possible because you have unmerged files') ||
      said('you need to resolve your current index first') ||
      said('committing is not possible because you have unmerged files')) {
    return GitProblem.mergeInProgress;
  }
  if (said('there is no merge to abort')) {
    return GitProblem.noMerge;
  }
  if (out.contains('nothing to commit') ||
      out.contains('no changes added to commit') ||
      said('nothing to commit')) {
    return GitProblem.nothingToCommit;
  }
  if (said('does not have any commits yet') ||
      said("bad default revision 'head'") ||
      said("ambiguous argument 'head'") ||
      said('you do not have the initial commit yet')) {
    return GitProblem.noCommits;
  }
  if (said('a branch named') && said('already exists')) {
    return GitProblem.branchExists;
  }
  if (said('is not a valid branch name')) {
    return GitProblem.invalidName;
  }
  if (said('not fully merged')) {
    return GitProblem.notFullyMerged;
  }
  if (said('cannot delete branch') && said('checked out')) {
    return GitProblem.currentBranch;
  }
  if (said('invalid reference:') ||
      (said('branch') && said('not found')) ||
      said('not a commit and a branch') ||
      said('no such branch')) {
    return GitProblem.noSuchBranch;
  }
  return GitProblem.gitError;
}

/// The app's words for [problem], for a snackbar or a dialog. git's own
/// words go with the failure ([GitFailure.stderr]) for its details.
String gitProblemMessage(GitProblem problem) => switch (problem) {
  GitProblem.notReady => 'The Linux runtime is not ready yet.',
  GitProblem.badRequest => 'Git was asked something it cannot do.',
  GitProblem.refused => 'CodeForge does not run that git command.',
  GitProblem.noSuchProject => 'The project is not there any more.',
  GitProblem.busy => 'Git is busy with this repository. Try again in a moment.',
  GitProblem.launchFailed => 'Git could not start.',
  GitProblem.timedOut => 'Git took too long and was stopped.',
  GitProblem.stopped => 'Stopped.',
  GitProblem.signaled => 'Git stopped unexpectedly.',
  GitProblem.tooLarge => 'The file is too large to show.',
  GitProblem.notARepository => 'This project is not a Git repository.',
  GitProblem.locked =>
    'Another git command is using this repository. If none is running, '
        'delete .git/index.lock from the terminal.',
  GitProblem.noIdentity =>
    'Set your name and email in Settings, Source control, before '
        'committing.',
  GitProblem.conflict =>
    'The merge has conflicts. Resolve them, then commit, or abort the '
        'merge.',
  GitProblem.localChanges =>
    'Your changes would be overwritten. Commit or discard them first.',
  GitProblem.mergeInProgress =>
    'A merge is in progress. Finish it or abort it first.',
  GitProblem.noMerge => 'There is no merge in progress.',
  GitProblem.nothingToCommit => 'There is nothing to commit.',
  GitProblem.noCommits => 'This repository has no commits yet.',
  GitProblem.branchExists => 'A branch with that name already exists.',
  GitProblem.invalidName => 'That is not a valid branch name.',
  GitProblem.notFullyMerged =>
    'That branch has commits that are not merged. Delete it anyway to lose '
        'them.',
  GitProblem.currentBranch =>
    'That branch is checked out. Switch to another branch first.',
  GitProblem.noSuchBranch => 'There is no such branch.',
  GitProblem.gitError => 'Git could not do that.',
  GitProblem.unavailable => 'Git runs on the Linux runtime, on Android.',
  GitProblem.unknown => 'Git could not do that.',
};
