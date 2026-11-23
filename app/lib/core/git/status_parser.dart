/// Reads `git status --porcelain=v2 -z --branch` (Phase 7 W2, PHASE_7_PLAN
/// W2): its records as the Git host cut them, one per NUL-terminated entry.
///
/// Porcelain v2 is git's stable, machine-readable status: headers
/// (`# branch.oid`, `# branch.head`, `# branch.upstream`, `# branch.ab`,
/// `# stash`), then one record per changed file: `1` ordinary, `2` renamed
/// or copied (its original path is the record after it), `u` unmerged, `?`
/// untracked, `!` ignored. Fields are separated by one space, and the path
/// is the rest of the record, spaces and newlines included.
///
/// A record the parser does not know, or cannot read, is skipped and never
/// throws: git may add headers, and a status the host ended at its cap may
/// stop inside a rename's pair (tested with W1's records and fuzzed in
/// test/core/git_parsers_test.dart).
library;

import 'git_models.dart';

/// [records] read into a status. [truncated] says the host ended the
/// listing at its cap.
GitStatus parseStatus(List<String> records, {bool truncated = false}) {
  String? head;
  String? oid;
  String? upstream;
  int? ahead;
  int? behind;
  int? stashes;
  final files = <GitFileStatus>[];
  var i = 0;
  while (i < records.length) {
    final record = records[i];
    i += 1;
    if (record.length < 2 || record[1] != ' ') {
      continue;
    }
    switch (record[0]) {
      case '#':
        final header = _fields(record, 3);
        if (header == null) {
          continue;
        }
        final value = header[2];
        switch (header[1]) {
          case 'branch.oid':
            oid = value == '(initial)' ? null : value;
          case 'branch.head':
            head = value == '(detached)' ? null : value;
          case 'branch.upstream':
            upstream = value.isEmpty ? null : value;
          case 'branch.ab':
            final counts = value.split(' ');
            if (counts.length == 2 &&
                counts[0].startsWith('+') &&
                counts[1].startsWith('-')) {
              ahead = int.tryParse(counts[0].substring(1));
              behind = int.tryParse(counts[1].substring(1));
            }
          case 'stash':
            stashes = int.tryParse(value);
        }
      case '1':
        final fields = _fields(record, 9);
        final xy = fields == null ? null : _changes(fields[1]);
        if (fields == null || xy == null || fields[8].isEmpty) {
          continue;
        }
        files.add(
          GitFileStatus(
            path: fields[8],
            kind: GitEntryKind.tracked,
            index: xy.$1,
            workTree: xy.$2,
            submodule: fields[2].startsWith('S'),
          ),
        );
      case '2':
        final fields = _fields(record, 10);
        final xy = fields == null ? null : _changes(fields[1]);
        if (fields == null || xy == null || fields[9].isEmpty) {
          continue;
        }
        // The original path is the next record; a status cut at its cap
        // may not have it.
        String? original;
        if (i < records.length) {
          original = records[i];
          i += 1;
        }
        final scoreField = fields[8];
        files.add(
          GitFileStatus(
            path: fields[9],
            kind: GitEntryKind.tracked,
            index: xy.$1,
            workTree: xy.$2,
            originalPath: original == null || original.isEmpty
                ? null
                : original,
            score: scoreField.length > 1
                ? int.tryParse(scoreField.substring(1))
                : null,
            submodule: fields[2].startsWith('S'),
          ),
        );
      case 'u':
        final fields = _fields(record, 11);
        final conflict = fields == null
            ? null
            : GitConflict.fromCode(fields[1]);
        if (fields == null || conflict == null || fields[10].isEmpty) {
          continue;
        }
        files.add(
          GitFileStatus(
            path: fields[10],
            kind: GitEntryKind.conflicted,
            index: GitChange.unmerged,
            workTree: GitChange.unmerged,
            conflict: conflict,
            submodule: fields[2].startsWith('S'),
          ),
        );
      case '?' || '!':
        final path = record.substring(2);
        if (path.isEmpty) {
          continue;
        }
        files.add(
          GitFileStatus(
            path: path,
            kind: record[0] == '?'
                ? GitEntryKind.untracked
                : GitEntryKind.ignored,
          ),
        );
    }
  }
  return GitStatus(
    branch: GitBranchState(
      head: head,
      oid: oid,
      upstream: upstream,
      ahead: upstream == null ? null : ahead,
      behind: upstream == null ? null : behind,
    ),
    files: files,
    truncated: truncated,
    stashes: stashes,
  );
}

/// [record]'s first [count] - 1 space-separated fields, then the rest as
/// the last; null when it has fewer.
List<String>? _fields(String record, int count) {
  final fields = <String>[];
  var start = 0;
  for (var n = 0; n < count - 1; n++) {
    final space = record.indexOf(' ', start);
    if (space < 0) {
      return null;
    }
    fields.add(record.substring(start, space));
    start = space + 1;
  }
  fields.add(record.substring(start));
  return fields;
}

/// An `XY` field read into its two changes; null unless it is two known
/// letters.
(GitChange, GitChange)? _changes(String xy) {
  if (xy.length != 2) {
    return null;
  }
  final index = GitChange.fromLetter(xy[0]);
  final workTree = GitChange.fromLetter(xy[1]);
  if (index == null || workTree == null) {
    return null;
  }
  return (index, workTree);
}
