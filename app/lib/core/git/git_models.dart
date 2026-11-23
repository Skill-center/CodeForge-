/// What the app knows of a repository (Phase 7 W2, PHASE_7_PLAN W2;
/// docs/GIT_ARCHITECTURE.md): read from git's machine-readable output by the
/// parsers beside this file, never from the words git prints for people.
///
/// Paths are relative to the project's folder and '/'-separated, as git
/// gives them with `core.quotePath=false` and `-z`: they match the
/// explorer's workspace paths.
library;

/// One side of a file's change: a letter of porcelain v2's `XY`, X for the
/// index against HEAD, Y for the work tree against the index.
enum GitChange {
  unmodified('.'),
  modified('M'),
  typeChanged('T'),
  added('A'),
  deleted('D'),
  renamed('R'),
  copied('C'),
  unmerged('U');

  const GitChange(this.letter);

  final String letter;

  static GitChange? fromLetter(String letter) {
    for (final change in values) {
      if (change.letter == letter) {
        return change;
      }
    }
    return null;
  }
}

/// How a merge left a conflicted file: porcelain v2's `XY` of a `u` record.
enum GitConflict {
  bothDeleted('DD'),
  addedByUs('AU'),
  deletedByThem('UD'),
  addedByThem('UA'),
  deletedByUs('DU'),
  bothAdded('AA'),
  bothModified('UU');

  const GitConflict(this.code);

  final String code;

  static GitConflict? fromCode(String code) {
    for (final conflict in values) {
      if (conflict.code == code) {
        return conflict;
      }
    }
    return null;
  }
}

/// Which list a file belongs to in the status.
enum GitEntryKind {
  /// Known to git, changed in the index, the work tree or both.
  tracked,

  /// New, unknown to git.
  untracked,

  /// Ignored by a `.gitignore` (listed only when asked for).
  ignored,

  /// Left unmerged by a merge.
  conflicted,
}

/// One changed file in the status.
final class GitFileStatus {
  const GitFileStatus({
    required this.path,
    required this.kind,
    this.index = GitChange.unmodified,
    this.workTree = GitChange.unmodified,
    this.originalPath,
    this.score,
    this.conflict,
    this.submodule = false,
  });

  /// Relative to the project, '/'-separated.
  final String path;

  final GitEntryKind kind;

  /// The index against HEAD.
  final GitChange index;

  /// The work tree against the index.
  final GitChange workTree;

  /// For a rename or a copy: where it came from.
  final String? originalPath;

  /// For a rename or a copy: how alike the two are, 0 to 100.
  final int? score;

  /// For a conflicted file: how the merge left it.
  final GitConflict? conflict;

  /// A submodule's entry (shown, not entered: submodules are out of scope).
  final bool submodule;

  /// It has changes in the index, to be committed.
  bool get staged =>
      kind == GitEntryKind.tracked && index != GitChange.unmodified;

  /// It has changes in the work tree, not staged.
  bool get unstaged =>
      kind == GitEntryKind.tracked && workTree != GitChange.unmodified;

  bool get untracked => kind == GitEntryKind.untracked;

  bool get conflicted => kind == GitEntryKind.conflicted;

  @override
  bool operator ==(Object other) =>
      other is GitFileStatus &&
      other.path == path &&
      other.kind == kind &&
      other.index == index &&
      other.workTree == workTree &&
      other.originalPath == originalPath &&
      other.score == score &&
      other.conflict == conflict &&
      other.submodule == submodule;

  @override
  int get hashCode => Object.hash(
    path,
    kind,
    index,
    workTree,
    originalPath,
    score,
    conflict,
    submodule,
  );

  @override
  String toString() =>
      'GitFileStatus($path, $kind, ${index.letter}${workTree.letter}'
      '${originalPath == null ? '' : ' from $originalPath'}'
      '${conflict == null ? '' : ' ${conflict!.code}'})';
}

/// The branch the work tree is on, from the status's headers.
final class GitBranchState {
  const GitBranchState({
    this.head,
    this.oid,
    this.upstream,
    this.ahead,
    this.behind,
  });

  /// The branch checked out; null when HEAD is detached.
  final String? head;

  /// HEAD's commit; null before the first commit.
  final String? oid;

  /// The branch it tracks (`origin/main`); null when none.
  final String? upstream;

  /// Commits ahead of and behind [upstream]; null without one, or when
  /// git could not tell (the upstream is gone).
  final int? ahead;
  final int? behind;

  bool get detached => head == null;

  /// No commit yet.
  bool get unborn => oid == null;

  /// What the status strip shows: the branch, or a detached HEAD's short
  /// commit.
  String get label {
    final branch = head;
    if (branch != null) {
      return branch;
    }
    final commit = oid;
    if (commit == null) {
      return 'HEAD';
    }
    return commit.length > 7 ? commit.substring(0, 7) : commit;
  }

  @override
  bool operator ==(Object other) =>
      other is GitBranchState &&
      other.head == head &&
      other.oid == oid &&
      other.upstream == upstream &&
      other.ahead == ahead &&
      other.behind == behind;

  @override
  int get hashCode => Object.hash(head, oid, upstream, ahead, behind);
}

/// A repository's status: its branch and its changed files.
final class GitStatus {
  const GitStatus({
    required this.branch,
    this.files = const [],
    this.truncated = false,
    this.stashes,
  });

  final GitBranchState branch;

  /// In git's order.
  final List<GitFileStatus> files;

  /// The host ended the listing at its cap: [files] is a beginning.
  final bool truncated;

  /// Stash entries, when asked for (`--show-stash`).
  final int? stashes;

  List<GitFileStatus> get staged => [
    for (final file in files)
      if (file.staged) file,
  ];

  List<GitFileStatus> get unstaged => [
    for (final file in files)
      if (file.unstaged) file,
  ];

  List<GitFileStatus> get untracked => [
    for (final file in files)
      if (file.untracked) file,
  ];

  List<GitFileStatus> get conflicted => [
    for (final file in files)
      if (file.conflicted) file,
  ];

  /// Files with any change, ignored ones aside.
  int get changeCount =>
      files.where((f) => f.kind != GitEntryKind.ignored).length;

  bool get clean => changeCount == 0;
}

/// One commit of the history.
final class GitCommit {
  const GitCommit({
    required this.hash,
    required this.parents,
    required this.authorName,
    required this.authorEmail,
    required this.authoredAt,
    required this.subject,
  });

  final String hash;

  /// None for a root commit, two or more for a merge.
  final List<String> parents;

  final String authorName;
  final String authorEmail;

  /// In UTC.
  final DateTime authoredAt;

  /// The message's first line.
  final String subject;

  String get shortHash => hash.length > 7 ? hash.substring(0, 7) : hash;

  bool get merge => parents.length > 1;

  @override
  bool operator ==(Object other) =>
      other is GitCommit &&
      other.hash == hash &&
      _sameList(other.parents, parents) &&
      other.authorName == authorName &&
      other.authorEmail == authorEmail &&
      other.authoredAt == authoredAt &&
      other.subject == subject;

  @override
  int get hashCode => Object.hash(
    hash,
    Object.hashAll(parents),
    authorName,
    authorEmail,
    authoredAt,
    subject,
  );
}

/// Where a branch lives.
enum GitBranchKind { local, remote }

/// One branch, local or a remote's, from `for-each-ref`.
final class GitBranch {
  const GitBranch({
    required this.name,
    required this.ref,
    required this.kind,
    required this.oid,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.upstreamGone = false,
    this.current = false,
    this.committedAt,
    this.subject = '',
  });

  /// Short: `main`, or `origin/main` for a remote's.
  final String name;

  /// In full: `refs/heads/main`.
  final String ref;

  final GitBranchKind kind;

  /// The commit it points at.
  final String oid;

  /// The branch it tracks, short (`origin/main`).
  final String? upstream;

  final int ahead;
  final int behind;

  /// Its upstream was deleted on the remote.
  final bool upstreamGone;

  /// Checked out.
  final bool current;

  /// When its last commit was made, in UTC.
  final DateTime? committedAt;

  /// Its last commit's subject.
  final String subject;

  @override
  bool operator ==(Object other) =>
      other is GitBranch &&
      other.name == name &&
      other.ref == ref &&
      other.kind == kind &&
      other.oid == oid &&
      other.upstream == upstream &&
      other.ahead == ahead &&
      other.behind == behind &&
      other.upstreamGone == upstreamGone &&
      other.current == current &&
      other.committedAt == committedAt &&
      other.subject == subject;

  @override
  int get hashCode => Object.hash(
    name,
    ref,
    kind,
    oid,
    upstream,
    ahead,
    behind,
    upstreamGone,
    current,
    committedAt,
    subject,
  );
}

/// A file a commit changed, against its parent.
final class GitCommitFile {
  const GitCommitFile({
    required this.path,
    required this.change,
    this.originalPath,
    this.score,
  });

  final String path;
  final GitChange change;

  /// For a rename or a copy: where it came from.
  final String? originalPath;
  final int? score;

  @override
  bool operator ==(Object other) =>
      other is GitCommitFile &&
      other.path == path &&
      other.change == change &&
      other.originalPath == originalPath &&
      other.score == score;

  @override
  int get hashCode => Object.hash(path, change, originalPath, score);

  @override
  String toString() =>
      'GitCommitFile(${change.letter} $path'
      '${originalPath == null ? '' : ' from $originalPath'})';
}

/// A line of git's progress, read.
final class GitProgress {
  const GitProgress({
    required this.phase,
    this.percent,
    this.done,
    this.total,
    this.finished = false,
    this.remote = false,
  });

  /// `Receiving objects`, `Updating files`, ...
  final String phase;

  /// 0 to 100, when git knows the total.
  final int? percent;

  /// Items done, and of how many.
  final int? done;
  final int? total;

  /// The phase's last line (`..., done.`).
  final bool finished;

  /// The remote's own progress, relayed (`remote: ...`).
  final bool remote;

  GitProgress copyWith({bool? finished}) => GitProgress(
    phase: phase,
    percent: percent,
    done: done,
    total: total,
    finished: finished ?? this.finished,
    remote: remote,
  );

  @override
  bool operator ==(Object other) =>
      other is GitProgress &&
      other.phase == phase &&
      other.percent == percent &&
      other.done == done &&
      other.total == total &&
      other.finished == finished &&
      other.remote == remote;

  @override
  int get hashCode =>
      Object.hash(phase, percent, done, total, finished, remote);

  @override
  String toString() =>
      'GitProgress($phase, ${percent ?? '-'}%, $done/$total'
      '${finished ? ', done' : ''}${remote ? ', remote' : ''})';
}

/// Who commits: the runtime home's `user.name` and `user.email`, shared
/// with the terminal's git.
final class GitIdentity {
  const GitIdentity({this.name, this.email});

  final String? name;
  final String? email;

  /// Both are set: a commit can be made.
  bool get complete =>
      (name?.trim().isNotEmpty ?? false) && (email?.trim().isNotEmpty ?? false);

  @override
  bool operator ==(Object other) =>
      other is GitIdentity && other.name == name && other.email == email;

  @override
  int get hashCode => Object.hash(name, email);
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
