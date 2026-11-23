/// Reads the history git gives in the formats the app asks for (Phase 7 W2,
/// PHASE_7_PLAN W2): `git log` with [gitLogFormat] and `-z`, `git
/// for-each-ref` with [gitRefFormat], and `git diff-tree --name-status -z`.
///
/// Each format separates its fields by a byte no field holds (the unit
/// separator, or NUL), so a subject with spaces, quotes or `%` reads back
/// as written. A record that does not read is skipped and never throws
/// (fuzzed in test/core/git_parsers_test.dart).
library;

import 'git_models.dart';

/// `git log`'s format: hash, parents, author's name, email and time, and
/// subject, apart by the unit separator; commits apart by NUL (`-z`).
const String gitLogFormat = '%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s';

/// `git for-each-ref`'s format: the ref, its commit, its upstream and how
/// far ahead and behind (`ahead 1, behind 2`, or `gone`), `*` when checked
/// out, its last commit's time and subject; apart by NUL, one ref a line.
const String gitRefFormat =
    '%(refname)%00%(objectname)%00%(upstream)%00'
    '%(upstream:track,nobracket)%00%(HEAD)%00%(committerdate:unix)%00'
    '%(subject)';

final RegExp _hash = RegExp(r'^[0-9a-f]{4,64}$');

/// [records], one commit each, read with [gitLogFormat].
List<GitCommit> parseLog(List<String> records) {
  final commits = <GitCommit>[];
  for (final record in records) {
    final fields = record.split('\u001f');
    if (fields.length < 6) {
      continue;
    }
    // A record may start after a newline git put between commits.
    final hash = fields[0].trim();
    final seconds = int.tryParse(fields[4]);
    if (!_hash.hasMatch(hash) || seconds == null) {
      continue;
    }
    commits.add(
      GitCommit(
        hash: hash,
        parents: [
          for (final parent in fields[1].split(' '))
            if (_hash.hasMatch(parent)) parent,
        ],
        authorName: fields[2],
        authorEmail: fields[3],
        authoredAt: _utc(seconds),
        subject: fields.sublist(5).join('\u001f'),
      ),
    );
  }
  return commits;
}

/// [lines], one ref each, read with [gitRefFormat]: local branches and
/// remotes' branches; a remote's `HEAD` and other refs are left out.
List<GitBranch> parseRefs(List<String> lines) {
  final branches = <GitBranch>[];
  for (final line in lines) {
    final fields = line.split('\u0000');
    if (fields.length < 7) {
      continue;
    }
    final ref = fields[0];
    final GitBranchKind kind;
    final String name;
    if (ref.startsWith('refs/heads/') && ref.length > 11) {
      kind = GitBranchKind.local;
      name = ref.substring(11);
    } else if (ref.startsWith('refs/remotes/') && ref.length > 13) {
      kind = GitBranchKind.remote;
      name = ref.substring(13);
      if (name.endsWith('/HEAD') || !name.contains('/')) {
        continue;
      }
    } else {
      continue;
    }
    final oid = fields[1];
    if (!_hash.hasMatch(oid)) {
      continue;
    }
    final upstreamRef = fields[2];
    final track = fields[3];
    final seconds = int.tryParse(fields[5]);
    branches.add(
      GitBranch(
        name: name,
        ref: ref,
        kind: kind,
        oid: oid,
        upstream: upstreamRef.isEmpty ? null : _shortRef(upstreamRef),
        ahead: _trackCount(track, 'ahead'),
        behind: _trackCount(track, 'behind'),
        upstreamGone: track == 'gone',
        current: fields[4] == '*',
        committedAt: seconds == null ? null : _utc(seconds),
        subject: fields.sublist(6).join('\u0000'),
      ),
    );
  }
  return branches;
}

/// [records] of `git diff-tree -r --name-status -z --no-commit-id`: for each
/// file its status letter, then its path, or for a rename or a copy its
/// score, then its old path and its new.
List<GitCommitFile> parseCommitFiles(List<String> records) {
  final files = <GitCommitFile>[];
  var i = 0;
  // Without --no-commit-id, the commit comes first.
  if (records.isNotEmpty && records[0].length >= 40 && _hash.hasMatch(records[0])) {
    i = 1;
  }
  while (i < records.length) {
    final status = records[i];
    i += 1;
    if (status.isEmpty) {
      continue;
    }
    final change = GitChange.fromLetter(status[0]);
    if (change == GitChange.renamed || change == GitChange.copied) {
      if (i + 1 >= records.length) {
        break;
      }
      final from = records[i];
      final to = records[i + 1];
      i += 2;
      if (to.isEmpty) {
        continue;
      }
      files.add(
        GitCommitFile(
          path: to,
          change: change!,
          originalPath: from.isEmpty ? null : from,
          score: int.tryParse(status.substring(1)),
        ),
      );
    } else {
      if (i >= records.length) {
        break;
      }
      final path = records[i];
      i += 1;
      // An unmerged (U) or unknown (X) entry, or one that does not read,
      // is passed over with its path.
      if (change == null ||
          change == GitChange.unmerged ||
          change == GitChange.unmodified ||
          status.length != 1 ||
          path.isEmpty) {
        continue;
      }
      files.add(GitCommitFile(path: path, change: change));
    }
  }
  return files;
}

/// [seconds] since the epoch, in UTC; a time a commit could only have been
/// given on purpose, past what a DateTime holds, is held at its limit.
DateTime _utc(int seconds) {
  final held = seconds > _maxSeconds
      ? _maxSeconds
      : seconds < -_maxSeconds
      ? -_maxSeconds
      : seconds;
  return DateTime.fromMillisecondsSinceEpoch(held * 1000, isUtc: true);
}

/// The most seconds a DateTime holds either side of the epoch.
const int _maxSeconds = 8640000000000;

/// `refs/remotes/origin/main` as `origin/main`, `refs/heads/main` as `main`.
String _shortRef(String ref) {
  if (ref.startsWith('refs/heads/')) {
    return ref.substring(11);
  }
  if (ref.startsWith('refs/remotes/')) {
    return ref.substring(13);
  }
  return ref;
}

/// `ahead 1, behind 2` read for [word]: its count, or 0.
int _trackCount(String track, String word) {
  for (final part in track.split(',')) {
    final words = part.trim().split(' ');
    if (words.length == 2 && words[0] == word) {
      return int.tryParse(words[1]) ?? 0;
    }
  }
  return 0;
}

/// A line of git's progress (`Receiving objects:  45% (450/1000), 1.20
/// MiB | 2.00 MiB/s`, `remote: Counting objects: 1234`, `Updating files:
/// 100% (10/10), done.`), or null when it is not one.
GitProgress? parseProgress(String text) {
  final match = _progress.firstMatch(text.trimRight());
  if (match == null) {
    return null;
  }
  final percent = int.tryParse(match.group(3) ?? '');
  return GitProgress(
    phase: match.group(2)!,
    percent: percent == null || percent <= 100 ? percent : 100,
    done: int.tryParse(match.group(4) ?? match.group(6) ?? ''),
    total: int.tryParse(match.group(5) ?? ''),
    finished: (match.group(7) ?? '').contains('done'),
    remote: match.group(1) != null,
  );
}

final RegExp _progress = RegExp(
  r'^(remote: )?([A-Za-z][A-Za-z ]*?):\s+'
  r'(?:(\d{1,3})%\s+\((\d+)/(\d+)\)|(\d+))(.*)$',
);
