/// Reading git (Phase 7 W2, gate G2): the parsers of porcelain v2, of `log`
/// and `for-each-ref` with NUL-separated formats, of `diff-tree`, and of
/// progress, each against git's real output in test/fixtures/git/ (written
/// by the host's own command lines: `-z`, the fixed settings, `LANG=C`),
/// and fuzzed: nothing they are given makes them throw, and every file
/// they read has a path. git's words for a failure read into the
/// problem each fixture names.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_errors.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/core/git/history_parser.dart';
import 'package:codeforge/core/git/status_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/git/$name.json').readAsStringSync())
        as Map<String, Object?>;

List<String> _records(String name) =>
    (_fixture(name)['records']! as List<Object?>).cast<String>();

GitStatus _status(String name) => parseStatus(_records(name));

GitFileStatus _file(GitStatus status, String path) =>
    status.files.singleWhere((f) => f.path == path);

final DateTime _fixtureTime = DateTime.utc(2026, 11, 24, 10);

void main() {
  group('the status', () {
    test('of a new repository: no commit, its files new', () {
      final status = _status('status_initial');
      expect(status.branch.head, 'main');
      expect(status.branch.unborn, isTrue);
      expect(status.branch.upstream, isNull);
      expect(status.files, const [
        GitFileStatus(path: 'a.txt', kind: GitEntryKind.untracked),
        GitFileStatus(path: 'src/b.txt', kind: GitEntryKind.untracked),
      ]);
      expect(status.untracked, hasLength(2));
      expect(status.clean, isFalse);
    });

    test('of a first file staged before any commit', () {
      final status = _status('status_unborn_staged');
      expect(status.branch.unborn, isTrue);
      final a = _file(status, 'a.txt');
      expect(a.index, GitChange.added);
      expect(a.workTree, GitChange.unmodified);
      expect(a.staged, isTrue);
      expect(a.unstaged, isFalse);
      expect(status.untracked.single.path, 'src/b.txt');
    });

    test('with every kind of change, names with spaces, newlines and '
        'accents as they are', () {
      final status = _status('status_changes');
      expect(status.branch.head, 'main');
      expect(status.branch.oid, hasLength(40));
      expect(status.files, hasLength(13));
      (GitChange, GitChange) xy(String path) =>
          (_file(status, path).index, _file(status, path).workTree);
      expect(xy('a.txt'), (GitChange.unmodified, GitChange.modified));
      expect(xy('b.txt'), (GitChange.modified, GitChange.unmodified));
      expect(xy('c.txt'), (GitChange.modified, GitChange.modified));
      expect(xy('d.txt'), (GitChange.unmodified, GitChange.deleted));
      expect(xy('e.txt'), (GitChange.deleted, GitChange.unmodified));
      expect(xy('h.txt'), (GitChange.added, GitChange.unmodified));
      expect(xy('t.txt'), (GitChange.unmodified, GitChange.typeChanged));
      expect(xy('ünï.txt'), (GitChange.unmodified, GitChange.modified));
      final renamed = _file(status, 'g.txt');
      expect(renamed.index, GitChange.renamed);
      expect(renamed.originalPath, 'f.txt');
      expect(renamed.score, 100);
      expect(
        [for (final f in status.untracked) f.path],
        ['.gitignore', 'new\nline.txt', 'u.txt', 'with space.txt'],
      );
      expect(
        [for (final f in status.staged) f.path],
        ['b.txt', 'c.txt', 'e.txt', 'g.txt', 'h.txt'],
      );
      expect(
        [for (final f in status.unstaged) f.path],
        ['a.txt', 'c.txt', 'd.txt', 't.txt', 'ünï.txt'],
      );
      // Ignored files are not listed unless asked for.
      expect(status.files.where((f) => f.path == 'debug.log'), isEmpty);
    });

    test('of a branch ahead of and behind its upstream', () {
      final status = _status('status_upstream');
      expect(status.branch.upstream, 'origin/main');
      expect(status.branch.ahead, 1);
      expect(status.branch.behind, 1);
      expect(status.clean, isTrue);
    });

    test('of a detached HEAD: its commit, short', () {
      final status = _status('status_detached');
      expect(status.branch.detached, isTrue);
      expect(status.branch.head, isNull);
      expect(status.branch.label, status.branch.oid!.substring(0, 7));
    });

    test(
      'after a merge stopped on conflicts: each conflict as git left it',
      () {
        final status = _status('status_conflicts');
        expect(
          {for (final f in status.conflicted) f.path: f.conflict},
          {
            'added.txt': GitConflict.bothAdded,
            'both.txt': GitConflict.bothModified,
            'ours_deleted.txt': GitConflict.deletedByUs,
            'theirs_deleted.txt': GitConflict.deletedByThem,
          },
        );
        expect(status.staged, isEmpty);
        expect(status.unstaged, isEmpty);
      },
    );

    test('cut at the cap inside a rename keeps what it has', () {
      final records = _records('status_changes');
      final rename = records.indexWhere((r) => r.startsWith('2 '));
      final cut = parseStatus(records.sublist(0, rename + 1), truncated: true);
      expect(cut.truncated, isTrue);
      final renamed = cut.files.last;
      expect(renamed.path, 'g.txt');
      expect(renamed.originalPath, isNull);
    });

    test('takes headers it does not know, and records it cannot read, as '
        'nothing', () {
      final status = parseStatus([
        '# branch.oid 0123456789012345678901234567890123456789',
        '# branch.head main',
        '# branch.future value',
        '# stash 2',
        '1 .M N... 100644',
        '1 ZZ N... 100644 100644 100644 a b c.txt',
        'u XY N... 1 2 3 4 a b c d.txt',
        '? ',
        '7 something new',
        '',
        '? kept.txt',
      ]);
      expect(status.stashes, 2);
      expect(status.files, const [
        GitFileStatus(path: 'kept.txt', kind: GitEntryKind.untracked),
      ]);
    });
  });

  group('the history', () {
    test("log's commits: hash, parents, author, time and subject", () {
      final commits = parseLog(_records('log'));
      expect(commits, hasLength(4));
      final merge = commits[0];
      expect(merge.merge, isTrue);
      expect(merge.parents, hasLength(2));
      expect(merge.subject, "Merge branch 'side'");
      expect(merge.authoredAt, _fixtureTime);
      final side = commits[2];
      expect(side.authorName, 'Zoë Ünïcode');
      expect(side.authorEmail, 'zoe@example.org');
      expect(side.subject, 'side: tabs\tand | pipes');
      expect(commits[3].parents, isEmpty);
      expect(commits[3].subject, 'first');
      expect(commits[1].parents, [commits[3].hash]);
      expect(merge.shortHash, merge.hash.substring(0, 7));
    });

    test("for-each-ref's branches: upstreams, ahead and behind, gone, the "
        'one checked out', () {
      final branches = parseRefs(_records('for_each_ref'));
      expect(
        [for (final b in branches) b.name],
        ['feature', 'main', 'origin/main'],
      );
      final feature = branches[0];
      expect(feature.kind, GitBranchKind.local);
      expect(feature.upstream, 'origin/feature');
      expect(feature.upstreamGone, isTrue);
      expect(feature.current, isFalse);
      expect(
        feature.subject,
        'feature: a subject with "quotes", 100% and ünïcode',
      );
      final main = branches[1];
      expect(main.current, isTrue);
      expect(main.upstream, 'origin/main');
      expect((main.ahead, main.behind), (1, 1));
      expect(main.committedAt, _fixtureTime);
      expect(branches[2].kind, GitBranchKind.remote);
      expect(branches[2].upstream, isNull);
    });

    test("diff-tree's files: changed, deleted, added and renamed", () {
      expect(parseCommitFiles(_records('diff_tree')), const [
        GitCommitFile(path: 'a.txt', change: GitChange.modified),
        GitCommitFile(path: 'm.txt', change: GitChange.deleted),
        GitCommitFile(path: 'n.txt', change: GitChange.added),
        GitCommitFile(
          path: 'renamed.txt',
          change: GitChange.renamed,
          originalPath: 's.txt',
          score: 100,
        ),
      ]);
      expect(parseCommitFiles(_records('diff_tree_root')), const [
        GitCommitFile(path: 'a.txt', change: GitChange.added),
      ]);
    });
  });

  group('progress', () {
    test("a clone's progress, as the host cuts it, reads line by line", () {
      final segments = (_fixture('progress')['segments']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final read = <GitProgress>[];
      for (final segment in segments) {
        final text = segment['text']! as String;
        final progress = parseProgress(text);
        if (text.startsWith('remote: Total')) {
          // git's summary, not a progress line.
          expect(progress, isNull);
          continue;
        }
        expect(progress, isNotNull, reason: text);
        read.add(progress!);
      }
      expect(
        {for (final p in read) p.phase},
        {'Counting objects', 'Compressing objects', 'Receiving objects'},
      );
      expect(read.first.remote, isTrue);
      expect(read.first.percent, 0);
      final last = read.last;
      expect(last.phase, 'Receiving objects');
      expect((last.percent, last.done, last.total), (100, 323, 323));
      expect(last.finished, isTrue);
      expect(last.remote, isFalse);
    });

    test('a count without a total, and what is no progress line', () {
      expect(
        parseProgress('remote: Enumerating objects: 323, done.        '),
        const GitProgress(
          phase: 'Enumerating objects',
          done: 323,
          finished: true,
          remote: true,
        ),
      );
      expect(
        parseProgress('Updating files:  45% (450/1000)'),
        const GitProgress(
          phase: 'Updating files',
          percent: 45,
          done: 450,
          total: 1000,
        ),
      );
      expect(parseProgress("Switched to branch 'main'"), isNull);
      expect(parseProgress(''), isNull);
      expect(parseProgress('Weird: 999% (1/2)')?.percent, 100);
    });
  });

  group("git's words", () {
    test('each failure in the fixtures reads as the problem it names', () {
      final cases = (_fixture('errors')['cases']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(cases, hasLength(13));
      for (final c in cases) {
        final problem = classifyGitError(
          exitCode: c['exitCode']! as int,
          stderr: c['stderr']! as String,
          stdout: (c['records']! as List<Object?>).cast<String>(),
        );
        expect(
          problem.code,
          c['problem'],
          reason: '${c['operation']}: ${c['stderr']}',
        );
      }
    });

    test('each remote failure reads as the problem it names (Phase 7 W3)', () {
      final cases = (_fixture('remote_errors')['cases']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(cases, hasLength(14));
      final problems = <String>{};
      for (final c in cases) {
        final problem = classifyGitError(
          exitCode: c['exitCode']! as int,
          stderr: c['stderr']! as String,
          stdout: (c['records']! as List<Object?>).cast<String>(),
        );
        expect(
          problem.code,
          c['problem'],
          reason: '${c['operation']} (${c['note']}): ${c['stderr']}',
        );
        problems.add(problem.code);
      }
      expect(problems, {
        'auth_failed',
        'no_credential',
        'repository_not_found',
        'offline',
        'rejected',
        'no_upstream',
        'conflict',
        'tls',
        'host_key_changed',
      });
      // The phone's libcurl is OpenSSL's, whose words differ from the
      // fixture machine's GnuTLS.
      expect(
        classifyGitError(
          exitCode: 128,
          stderr:
              "fatal: unable to access 'https://h/r.git/': SSL certificate "
              'problem: self-signed certificate\n',
        ),
        GitProblem.tls,
      );
    });

    test('a merge that stopped on conflicts says so on stdout', () {
      final merge = _fixture('merge_conflict');
      expect(merge['exitCode'], 1);
      expect(
        classifyGitError(
          exitCode: 1,
          stderr: merge['stderr']! as String,
          stdout: _records('merge_conflict'),
        ),
        GitProblem.conflict,
      );
    });

    test('words it does not know read as a plain git error, and every '
        'problem has words for the app', () {
      expect(
        classifyGitError(exitCode: 128, stderr: 'fatal: something new'),
        GitProblem.gitError,
      );
      for (final problem in GitProblem.values) {
        expect(gitProblemMessage(problem), isNotEmpty);
      }
    });
  });

  group('fuzzed', () {
    const alphabet = ' #12uM.ADRCTU?!NSabc/\n\u001f\u0000ü-+()%:*,refs/heads/';
    String noise(Random random, int max) => String.fromCharCodes([
      for (var i = random.nextInt(max); i > 0; i--)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);

    void parseEverything(List<String> records) {
      final status = parseStatus(records);
      for (final file in status.files) {
        expect(file.path, isNotEmpty);
      }
      for (final commit in parseLog(records)) {
        expect(commit.hash, isNotEmpty);
      }
      for (final branch in parseRefs(records)) {
        expect(branch.name, isNotEmpty);
      }
      for (final file in parseCommitFiles(records)) {
        expect(file.path, isNotEmpty);
      }
      for (final record in records) {
        parseProgress(record);
      }
    }

    test('a commit time past what a date holds is held at its limit', () {
      final commits = parseLog([
        '${'a' * 40}\u001f\u001fA\u001fa@b\u001f99999999999999999\u001fx',
      ]);
      expect(commits.single.authoredAt.isUtc, isTrue);
      expect(
        commits.single.authoredAt,
        DateTime.fromMillisecondsSinceEpoch(8640000000000000, isUtc: true),
      );
    });

    test('noise never throws', () {
      final random = Random(20261124);
      for (var round = 0; round < 3000; round++) {
        parseEverything([
          for (var i = random.nextInt(12); i > 0; i--) noise(random, 60),
        ]);
      }
    });

    test("git's records, cut, dropped and mangled, never throw", () {
      final random = Random(7);
      const names = [
        'status_initial',
        'status_unborn_staged',
        'status_changes',
        'status_upstream',
        'status_detached',
        'status_conflicts',
        'log',
        'for_each_ref',
        'diff_tree',
        'diff_tree_root',
      ];
      for (final name in names) {
        final records = _records(name);
        for (var round = 0; round < 300; round++) {
          final mangled = [...records];
          if (mangled.isNotEmpty) {
            // Cut the list, as the cap does.
            mangled.removeRange(random.nextInt(mangled.length), mangled.length);
          }
          for (var i = 0; i < mangled.length; i++) {
            final record = mangled[i];
            switch (random.nextInt(4)) {
              case 0 when record.isNotEmpty:
                mangled[i] = record.substring(0, random.nextInt(record.length));
              case 1 when record.isNotEmpty:
                final at = random.nextInt(record.length);
                mangled[i] =
                    record.substring(0, at) +
                    noise(random, 4) +
                    record.substring(at);
              case 2 when random.nextInt(5) == 0:
                mangled[i] = '';
              default:
                break;
            }
          }
          parseEverything(mangled);
        }
      }
    });
  });
}
