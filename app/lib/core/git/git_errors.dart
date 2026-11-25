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
  // The remotes (Phase 7 W3; test/fixtures/git/remote_errors.json): ssh's
  // and curl's words first, since git's own around them are the same for
  // every failure ("Could not read from remote repository").
  if (said('could not read username') ||
      said('could not read password') ||
      said('terminal prompts disabled')) {
    return GitProblem.noCredential;
  }
  if (said('authentication failed') ||
      said('permission denied (publickey') ||
      said('invalid username or password') ||
      said('the requested url returned error: 403') ||
      said('the requested url returned error: 401')) {
    return GitProblem.authFailed;
  }
  if (said('host key verification failed') ||
      said('remote host identification has changed')) {
    return GitProblem.hostKeyChanged;
  }
  if (said('ssl certificate problem') ||
      said('server certificate verification failed') ||
      said('certificate verify failed') ||
      said('unable to get local issuer certificate')) {
    return GitProblem.tls;
  }
  if (said('repository not found') ||
      (said("repository '") && said("' not found")) ||
      said('does not appear to be a git repository') ||
      said('the requested url returned error: 404')) {
    return GitProblem.repositoryNotFound;
  }
  if (said('could not resolve host') ||
      said('could not resolve hostname') ||
      said('failed to connect to') ||
      said("couldn't connect to server") ||
      said('connection refused') ||
      said('connection timed out') ||
      said('operation timed out') ||
      said('network is unreachable') ||
      said('no route to host') ||
      said('temporary failure in name resolution')) {
    return GitProblem.offline;
  }
  if (said('[rejected]') ||
      said('failed to push some refs') ||
      said('non-fast-forward')) {
    return GitProblem.rejected;
  }
  if (said('has no upstream branch') ||
      said('there is no tracking information')) {
    return GitProblem.noUpstream;
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
  GitProblem.exists => 'A project with that name exists. Choose another.',
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
  GitProblem.authFailed =>
    'The host refused the credential. Check the token, or the SSH key in '
        'the host\'s settings.',
  GitProblem.noCredential => 'No credential was given, so the host refused.',
  GitProblem.repositoryNotFound =>
    'There is no such repository, or this account cannot see it.',
  GitProblem.offline =>
    'The host cannot be reached. Check the connection and the URL.',
  GitProblem.rejected =>
    'The remote has commits this branch does not. Pull first, then push.',
  GitProblem.tls =>
    'The host\'s certificate was not accepted, so nothing was sent.',
  GitProblem.hostKeyChanged =>
    'The host\'s SSH key is not the one trusted. If it changed for a good '
        'reason, remove it from known_hosts in the terminal.',
  GitProblem.noUpstream =>
    'This branch has no upstream yet. Push it first to set one.',
  GitProblem.gitError => 'Git could not do that.',
  GitProblem.unavailable => 'Git runs on the Linux runtime, on Android.',
  GitProblem.unknown => 'Git could not do that.',
};
