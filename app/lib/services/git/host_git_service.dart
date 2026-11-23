/// Git for the app over the Kotlin host (Phase 7 W2, PHASE_7_PLAN W2;
/// docs/GIT_ARCHITECTURE.md): each operation as the git command the host
/// runs, its output read by the parsers in lib/core/git/, and a command
/// that failed read into a [GitProblem] (core/git/git_errors.dart).
///
/// The host takes only the operations and options it lists
/// (android/…/git/GitCommands.kt); the commands here are exactly those,
/// checked in test/services/git_service_test.dart. Paths always come after
/// `--`, so a file named like an option is still a file.
library;

import '../../core/errors/failure.dart';
import '../../core/git/git_errors.dart';
import '../../core/git/git_models.dart';
import '../../core/git/history_parser.dart';
import '../../core/git/status_parser.dart';
import '../contracts.dart';

final class HostGitService implements GitService {
  HostGitService(this._host);

  final GitHost _host;

  /// The most files a status lists by default: a tree of new files whose
  /// folder has no `.gitignore` shows its first ones, truncated.
  static const int defaultMaxFiles = 100000;

  @override
  bool get available => _host.available;

  @override
  Future<Result<GitStatus>> status(String project, {int? maxFiles}) async {
    // A rename takes two records, and the headers up to five.
    final limit = (maxFiles ?? defaultMaxFiles) * 2 + 8;
    final ran = await _run(
      project,
      'status',
      const ['--branch', '--untracked-files=all'],
      maxRecords: limit,
    );
    return switch (ran) {
      Ok<GitOutcome>(:final value) => Ok(
        parseStatus(value.records, truncated: value.truncated),
      ),
      Err<GitOutcome>(:final failure) => Err(failure),
    };
  }

  @override
  Future<Result<void>> stage(String project, List<String> paths) async {
    if (paths.isEmpty) {
      return const Ok(null);
    }
    return _done(await _run(project, 'add', ['-A', '--', ...paths]));
  }

  @override
  Future<Result<void>> stageAll(String project) async =>
      _done(await _run(project, 'add', const ['-A']));

  @override
  Future<Result<void>> unstage(String project, List<String> paths) async {
    if (paths.isEmpty) {
      return const Ok(null);
    }
    // Before the first commit there is no HEAD to restore from: the paths
    // only leave the index.
    final head = await _host.run(
      GitInvocation(
        'rev-parse',
        const ['--verify', '-q', 'HEAD'],
        project: project,
      ),
    );
    switch (head) {
      case Err<GitOutcome>(:final failure):
        return Err(failure);
      case Ok<GitOutcome>(:final value) when value.exitCode == 1:
        return _done(
          await _run(project, 'rm', [
            '--cached',
            '-r',
            '-q',
            '--ignore-unmatch',
            '--',
            ...paths,
          ]),
        );
      case Ok<GitOutcome>(:final value) when !value.ok:
        return Err(_failureOf(value));
      case Ok<GitOutcome>():
        return _done(
          await _run(project, 'restore', ['--staged', '-q', '--', ...paths]),
        );
    }
  }

  @override
  Future<Result<void>> discard(String project, List<String> paths) async {
    if (paths.isEmpty) {
      return const Ok(null);
    }
    return _done(
      await _run(project, 'restore', ['--worktree', '-q', '--', ...paths]),
    );
  }

  @override
  Future<Result<void>> deleteUntracked(
    String project,
    List<String> paths,
  ) async {
    if (paths.isEmpty) {
      return const Ok(null);
    }
    return _done(await _run(project, 'clean', ['-f', '-q', '--', ...paths]));
  }

  @override
  Future<Result<void>> commit(
    String project,
    String message, {
    bool amend = false,
  }) async {
    final keepMessage = amend && message.trim().isEmpty;
    if (!keepMessage && message.trim().isEmpty) {
      return const Err(
        GitFailure(
          'Write a commit message first.',
          problem: GitProblem.badRequest,
          operation: 'commit',
        ),
      );
    }
    return _done(
      await _run(project, 'commit', [
        '-q',
        if (amend) '--amend',
        if (keepMessage) '--no-edit' else ...['-m', message],
      ]),
    );
  }

  @override
  Future<Result<List<GitCommit>>> log(
    String project, {
    int max = 100,
    int skip = 0,
    String? path,
  }) async {
    final ran = await _run(project, 'log', [
      '-n',
      '${max.clamp(1, 100000)}',
      if (skip > 0) '--skip=$skip',
      '--format=$gitLogFormat',
      if (path != null) ...['--', path],
    ]);
    return switch (ran) {
      Ok<GitOutcome>(:final value) => Ok(parseLog(value.records)),
      // No commit yet: no history, not a failure.
      Err<GitOutcome>(failure: GitFailure(problem: GitProblem.noCommits)) =>
        const Ok(<GitCommit>[]),
      Err<GitOutcome>(:final failure) => Err(failure),
    };
  }

  @override
  Future<Result<List<GitCommitFile>>> commitFiles(
    String project,
    String commit, {
    String? parent,
  }) async {
    final ran = await _run(project, 'diff-tree', [
      '-r',
      '--root',
      '--name-status',
      '-M',
      '--no-commit-id',
      if (parent != null) parent,
      commit,
    ]);
    return switch (ran) {
      Ok<GitOutcome>(:final value) => Ok(parseCommitFiles(value.records)),
      Err<GitOutcome>(:final failure) => Err(failure),
    };
  }

  @override
  Future<Result<String>> fileAt(
    String project,
    String path, {
    String? revision,
  }) async {
    final ran = await _run(project, 'cat-file', [
      'blob',
      revision == null ? ':$path' : '$revision:$path',
    ]);
    return switch (ran) {
      // An empty file has no record.
      Ok<GitOutcome>(:final value) => Ok(
        value.records.isEmpty ? '' : value.records.join(),
      ),
      Err<GitOutcome>(:final failure) => Err(failure),
    };
  }

  @override
  Future<Result<List<GitBranch>>> branches(String project) async {
    final ran = await _run(project, 'for-each-ref', const [
      '--format=$gitRefFormat',
      '--sort=refname',
      'refs/heads/',
      'refs/remotes/',
    ]);
    return switch (ran) {
      Ok<GitOutcome>(:final value) => Ok(parseRefs(value.records)),
      Err<GitOutcome>(:final failure) => Err(failure),
    };
  }

  @override
  Future<Result<void>> createBranch(
    String project,
    String name, {
    String? from,
    bool switchTo = true,
  }) async => _done(
    await _run(
      project,
      switchTo ? 'switch' : 'branch',
      [
        '-q',
        if (switchTo) '--create',
        name,
        if (from != null) from,
      ],
    ),
  );

  @override
  Future<Result<void>> switchBranch(
    String project,
    String name, {
    void Function(GitProgress progress)? onProgress,
  }) async => _done(
    await _run(
      project,
      'switch',
      [if (onProgress != null) '--progress' else '-q', name],
      onProgress: _progressTo(onProgress),
    ),
  );

  @override
  Future<Result<void>> deleteBranch(
    String project,
    String name, {
    bool force = false,
  }) async =>
      _done(await _run(project, 'branch', [force ? '-D' : '-d', '-q', name]));

  @override
  Future<Result<void>> merge(
    String project,
    String branch, {
    void Function(GitProgress progress)? onProgress,
  }) async => _done(
    await _run(
      project,
      'merge',
      ['--no-edit', if (onProgress != null) '--progress', branch],
      onProgress: _progressTo(onProgress),
    ),
  );

  @override
  Future<Result<void>> abortMerge(String project) async =>
      _done(await _run(project, 'merge', const ['--abort']));

  @override
  Future<Result<void>> init(
    String project, {
    String initialBranch = 'main',
  }) async => _done(
    await _run(project, 'init', ['-q', '--initial-branch=$initialBranch']),
  );

  @override
  Future<Result<GitIdentity>> identity() async {
    final name = await _identityPart('user.name');
    final email = await _identityPart('user.email');
    return switch ((name, email)) {
      (Ok<String?>(value: final n), Ok<String?>(value: final e)) => Ok(
        GitIdentity(name: n, email: e),
      ),
      (Err<String?>(:final failure), _) => Err(failure),
      (_, Err<String?>(:final failure)) => Err(failure),
    };
  }

  /// One key of the identity: null when it is not set (git exits 1).
  Future<Result<String?>> _identityPart(String key) async {
    final ran = await _host.run(
      GitInvocation('config', ['--global', '--get', key]),
    );
    return switch (ran) {
      Err<GitOutcome>(:final failure) => Err(failure),
      Ok<GitOutcome>(:final value) when value.exitCode == 1 => const Ok(null),
      Ok<GitOutcome>(:final value) when !value.ok => Err(_failureOf(value)),
      Ok<GitOutcome>(:final value) => Ok(
        value.records.isEmpty ? null : value.records.first,
      ),
    };
  }

  @override
  Future<Result<void>> setIdentity(GitIdentity identity) async {
    // One after the other: each is a change to the same file, and the host
    // runs one change at a time per place.
    for (final (key, value) in [
      ('user.name', identity.name),
      ('user.email', identity.email),
    ]) {
      final text = value?.trim() ?? '';
      final ran = await _host.run(
        GitInvocation(
          'config',
          text.isEmpty ? ['--global', '--unset', key] : ['--global', key, text],
        ),
      );
      switch (ran) {
        case Err<GitOutcome>(:final failure):
          return Err(failure);
        // Unsetting a key that is not set (5) leaves it unset.
        case Ok<GitOutcome>(:final value)
            when text.isEmpty && value.exitCode == 5:
          continue;
        case Ok<GitOutcome>(:final value) when !value.ok:
          return Err(_failureOf(value));
        case Ok<GitOutcome>():
          continue;
      }
    }
    return const Ok(null);
  }

  @override
  Future<Result<bool>> isValidBranchName(String name) async {
    // What the host would refuse as an option, or git as a name, without
    // asking either.
    if (name.isEmpty ||
        name.startsWith('-') ||
        name.length > 255 ||
        name.runes.any((r) => r <= 0x20 || r == 0x7f)) {
      return const Ok(false);
    }
    final ran = await _host.run(
      GitInvocation('check-ref-format', ['--branch', name]),
    );
    return switch (ran) {
      Ok<GitOutcome>(:final value) => Ok(value.exitCode == 0),
      Err<GitOutcome>(
        failure: GitFailure(
          problem: GitProblem.badRequest || GitProblem.refused,
        ),
      ) =>
        const Ok(false),
      Err<GitOutcome>(:final failure) => Err(failure),
    };
  }

  /// Runs one command in [project]: its outcome when git succeeded, the
  /// failure git's words name when it did not, or the host's failure.
  Future<Result<GitOutcome>> _run(
    String project,
    String operation,
    List<String> arguments, {
    int? maxRecords,
    void Function(String text, bool closing)? onProgress,
  }) async {
    final ran = await _host.run(
      GitInvocation(
        operation,
        arguments,
        project: project,
        maxRecords: maxRecords,
      ),
      onProgress: onProgress,
    );
    return switch (ran) {
      Ok<GitOutcome>(:final value) when !value.ok => Err(_failureOf(value)),
      _ => ran,
    };
  }

  static Result<void> _done(Result<GitOutcome> ran) => switch (ran) {
    Ok<GitOutcome>() => const Ok(null),
    Err<GitOutcome>(:final failure) => Err(failure),
  };

  /// A command git ended with an error, read into its problem.
  static GitFailure _failureOf(GitOutcome outcome) {
    final problem = classifyGitError(
      exitCode: outcome.exitCode ?? -1,
      stderr: outcome.stderr,
      stdout: outcome.records,
    );
    return GitFailure(
      gitProblemMessage(problem),
      problem: problem,
      operation: outcome.operation,
      exitCode: outcome.exitCode,
      stderr: outcome.stderr,
    );
  }

  /// git's progress lines, read, to [onProgress]; lines that do not read
  /// are passed over.
  static void Function(String text, bool closing)? _progressTo(
    void Function(GitProgress progress)? onProgress,
  ) {
    if (onProgress == null) {
      return null;
    }
    return (text, closing) {
      final progress = parseProgress(text);
      if (progress != null) {
        onProgress(closing ? progress.copyWith(finished: true) : progress);
      }
    };
  }
}
