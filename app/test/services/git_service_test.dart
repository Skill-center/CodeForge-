/// Git from Dart (Phase 7 W2, gate G2): the real service over a scripted
/// host sends exactly the commands the host lists (each with its paths
/// after `--`), reads their output, and reads a failure into its problem;
/// the Pigeon client against mocked host channels (a run, its records,
/// progress and exit, events that come before the answer, a refusal, a
/// stop, no host at all); and the honest fake.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/fakes.dart';
import 'package:codeforge/services/git/host_git_service.dart';
import 'package:codeforge/services/git/native/git_api.g.dart';
import 'package:codeforge/services/git/native/pigeon_git_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_git_host.dart';

List<String> _records(String name) =>
    ((jsonDecode(File('test/fixtures/git/$name.json').readAsStringSync())
                as Map<String, Object?>)['records']!
            as List<Object?>)
        .cast<String>();

Matcher _fails(GitProblem problem) => isA<Err<Object?>>().having(
  (e) => e.failure,
  'failure',
  isA<GitFailure>().having((f) => f.problem, 'problem', problem),
);

void main() {
  group('the service', () {
    late ScriptedGitHost host;
    late HostGitService git;

    setUp(() {
      host = ScriptedGitHost();
      git = HostGitService(host);
    });

    test("reads a project's status from its porcelain v2 records", () async {
      host.answer = (_) => GitScript(records: _records('status_changes'));
      final status = (await git.status('demo')).orThrow;
      expect(host.commands.single, [
        'status',
        '--branch',
        '--untracked-files=all',
      ]);
      expect(host.invocations.single.project, 'demo');
      expect(
        host.invocations.single.maxRecords,
        HostGitService.defaultMaxFiles * 2 + 8,
      );
      expect(status.files, hasLength(13));
      expect(status.branch.head, 'main');
    });

    test('a status ended at the cap says it is a beginning', () async {
      host.answer = (_) => GitScript(
        exitCode: null,
        truncated: true,
        records: _records('status_initial').sublist(0, 3),
      );
      final status = (await git.status('demo', maxFiles: 1)).orThrow;
      expect(status.truncated, isTrue);
      expect(host.invocations.single.maxRecords, 10);
    });

    test('stages, unstages and discards the paths named, after --', () async {
      await git.stage('demo', ['a.txt', '-n.txt', 'with space.txt']);
      await git.stageAll('demo');
      await git.unstage('demo', ['a.txt']);
      await git.discard('demo', ['b.txt']);
      await git.deleteUntracked('demo', ['new.txt']);
      expect(host.commands, [
        ['add', '-A', '--', 'a.txt', '-n.txt', 'with space.txt'],
        ['add', '-A'],
        ['rev-parse', '--verify', '-q', 'HEAD'],
        ['restore', '--staged', '-q', '--', 'a.txt'],
        ['restore', '--worktree', '-q', '--', 'b.txt'],
        ['clean', '-f', '-q', '--', 'new.txt'],
      ]);
      // Nothing named, nothing run.
      await git.stage('demo', []);
      await git.unstage('demo', []);
      expect(host.commands, hasLength(6));
    });

    test('before the first commit, unstaging takes the paths out of the '
        'index', () async {
      host.answer = (invocation) => invocation.operation == 'rev-parse'
          ? const GitScript(exitCode: 1)
          : const GitScript();
      expect((await git.unstage('demo', ['a.txt'])).isOk, isTrue);
      expect(host.commands.last, [
        'rm',
        '--cached',
        '-r',
        '-q',
        '--ignore-unmatch',
        '--',
        'a.txt',
      ]);
    });

    test('commits with a message, amends with or without one', () async {
      await git.commit('demo', 'Fix the thing\n\nBecause.');
      await git.commit('demo', 'Better words', amend: true);
      await git.commit('demo', '', amend: true);
      expect(host.commands, [
        ['commit', '-q', '-m', 'Fix the thing\n\nBecause.'],
        ['commit', '-q', '--amend', '-m', 'Better words'],
        ['commit', '-q', '--amend', '--no-edit'],
      ]);
      expect(await git.commit('demo', '  '), _fails(GitProblem.badRequest));
      expect(host.commands, hasLength(3));
    });

    test('a commit with nothing staged, or no identity, says so', () async {
      host.answer = (_) => const GitScript(
        exitCode: 1,
        records: ['On branch main', 'nothing to commit, working tree clean'],
      );
      expect(await git.commit('demo', 'x'), _fails(GitProblem.nothingToCommit));
      host.answer = (_) => const GitScript(
        exitCode: 128,
        stderr:
            'Author identity unknown\n\n*** Please tell me who you are.\n'
            'fatal: no email was given and auto-detection is disabled\n',
      );
      final failed = await git.commit('demo', 'x');
      expect(failed, _fails(GitProblem.noIdentity));
      final failure = failed.failureOrNull! as GitFailure;
      expect(failure.exitCode, 128);
      expect(failure.stderr, contains('Author identity unknown'));
      expect(failure.operation, 'commit');
    });

    test('reads the history; before the first commit there is none', () async {
      host.answer = (_) => GitScript(records: _records('log'));
      final commits = (await git.log(
        'demo',
        max: 50,
        skip: 10,
        path: 'a.txt',
      )).orThrow;
      expect(commits, hasLength(4));
      expect(host.commands.single, [
        'log',
        '-n',
        '50',
        '--skip=10',
        '--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s',
        '--',
        'a.txt',
      ]);
      host.answer = (_) => const GitScript(
        exitCode: 128,
        stderr:
            "fatal: your current branch 'main' does not have any commits "
            'yet\n',
      );
      expect((await git.log('demo')).orThrow, isEmpty);
    });

    test("a commit's files against its parent, and a file's text", () async {
      host.answer = (invocation) => switch (invocation.operation) {
        'diff-tree' => GitScript(records: _records('diff_tree')),
        _ => const GitScript(records: ['hello\n']),
      };
      expect(
        (await git.commitFiles('demo', 'abc123', parent: 'def456')).orThrow,
        hasLength(4),
      );
      expect((await git.fileAt('demo', 'src/a.txt')).orThrow, 'hello\n');
      expect(
        (await git.fileAt('demo', 'src/a.txt', revision: 'HEAD')).orThrow,
        'hello\n',
      );
      expect(host.commands, [
        [
          'diff-tree',
          '-r',
          '--root',
          '--name-status',
          '-M',
          '--no-commit-id',
          'def456',
          'abc123',
        ],
        ['cat-file', 'blob', ':src/a.txt'],
        ['cat-file', 'blob', 'HEAD:src/a.txt'],
      ]);
      host.answer = (_) => const GitScript();
      expect((await git.fileAt('demo', 'empty.txt')).orThrow, '');
      host.answer = (_) => const GitScript(problem: GitProblem.tooLarge);
      expect(await git.fileAt('demo', 'big.bin'), _fails(GitProblem.tooLarge));
    });

    test('branches: listed, made, switched, deleted, merged', () async {
      host.answer = (invocation) => invocation.operation == 'for-each-ref'
          ? GitScript(records: _records('for_each_ref'))
          : const GitScript();
      expect((await git.branches('demo')).orThrow, hasLength(3));
      await git.createBranch('demo', 'feature/x');
      await git.createBranch('demo', 'later', from: 'main', switchTo: false);
      await git.switchBranch('demo', 'main');
      await git.deleteBranch('demo', 'later');
      await git.deleteBranch('demo', 'feature/x', force: true);
      await git.merge('demo', 'feature/y');
      await git.abortMerge('demo');
      await git.init('demo');
      expect(host.commands, [
        [
          'for-each-ref',
          '--format=%(refname)%00%(objectname)%00%(upstream)%00'
              '%(upstream:track,nobracket)%00%(HEAD)%00%(committerdate:unix)'
              '%00%(subject)',
          '--sort=refname',
          'refs/heads/',
          'refs/remotes/',
        ],
        ['switch', '-q', '--create', 'feature/x'],
        ['branch', '-q', 'later', 'main'],
        ['switch', '-q', 'main'],
        ['branch', '-d', '-q', 'later'],
        ['branch', '-D', '-q', 'feature/x'],
        ['merge', '--no-edit', 'feature/y'],
        ['merge', '--abort'],
        ['init', '-q', '--initial-branch=main'],
      ]);
    });

    test("a switch's progress reaches its listener, read", () async {
      host.answer = (_) => const GitScript(
        progress: [
          ('Updating files:  50% (5/10)', false),
          ('Updating files: 100% (10/10), done.', true),
          ('not progress', false),
        ],
      );
      final heard = <GitProgress>[];
      await git.switchBranch('demo', 'big', onProgress: heard.add);
      expect(host.commands.single, ['switch', '--progress', 'big']);
      expect(heard, const [
        GitProgress(phase: 'Updating files', percent: 50, done: 5, total: 10),
        GitProgress(
          phase: 'Updating files',
          percent: 100,
          done: 10,
          total: 10,
          finished: true,
        ),
      ]);
    });

    test('a merge that stops on conflicts fails as a conflict', () async {
      host.answer = (_) =>
          GitScript(exitCode: 1, records: _records('merge_conflict'));
      expect(await git.merge('demo', 'other'), _fails(GitProblem.conflict));
    });

    test(
      "the identity: read from the runtime's home, set, and unset",
      () async {
        host.answer = (invocation) => switch (invocation.arguments.last) {
          'user.name' => const GitScript(records: ['Ada Lovelace']),
          _ => const GitScript(exitCode: 1),
        };
        final identity = (await git.identity()).orThrow;
        expect(identity, const GitIdentity(name: 'Ada Lovelace'));
        expect(identity.complete, isFalse);
        expect(host.invocations.every((i) => i.project == null), isTrue);
        host.invocations.clear();
        host.answer = (invocation) => invocation.arguments.contains('--unset')
            ? const GitScript(exitCode: 5)
            : const GitScript();
        final set = await git.setIdentity(
          const GitIdentity(name: ' Ada Lovelace ', email: ''),
        );
        expect(set.isOk, isTrue);
        expect(host.commands, [
          ['config', '--global', 'user.name', 'Ada Lovelace'],
          ['config', '--global', '--unset', 'user.email'],
        ]);
        host.answer = (_) => const GitScript(problem: GitProblem.busy);
        expect(
          await git.setIdentity(const GitIdentity(name: 'x', email: 'y')),
          _fails(GitProblem.busy),
        );
      },
    );

    test('a branch name is checked by git, and what reads as an option '
        'never reaches it', () async {
      host.answer = (invocation) => invocation.arguments.last == 'good'
          ? const GitScript(records: ['good'])
          : const GitScript(exitCode: 128);
      expect((await git.isValidBranchName('good')).orThrow, isTrue);
      expect((await git.isValidBranchName('bad..name')).orThrow, isFalse);
      for (final name in ['', '-delete', 'a b', 'tab\there']) {
        expect((await git.isValidBranchName(name)).orThrow, isFalse);
      }
      expect(host.commands, [
        ['check-ref-format', '--branch', 'good'],
        ['check-ref-format', '--branch', 'bad..name'],
      ]);
    });

    test("the host's refusals and ends pass through as they are", () async {
      for (final problem in [
        GitProblem.busy,
        GitProblem.refused,
        GitProblem.noSuchProject,
        GitProblem.notReady,
        GitProblem.timedOut,
        GitProblem.stopped,
      ]) {
        host.answer = (_) => GitScript(problem: problem);
        expect(await git.status('demo'), _fails(problem));
      }
      host.answer = (_) => const GitScript(
        exitCode: 128,
        stderr:
            'fatal: not a git repository (or any of the parent '
            'directories): .git\n',
      );
      expect(await git.status('demo'), _fails(GitProblem.notARepository));
    });
  });

  group('the Pigeon host', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const prefix = 'dev.flutter.pigeon.codeforge.GitApi';
    const events = 'dev.flutter.pigeon.codeforge.GitEvents';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = GitApi.pigeonChannelCodec;

    late List<List<Object?>> asked;

    void answer(String method, Object? Function(List<Object?> args) reply) {
      messenger.setMockMessageHandler('$prefix.$method', (message) async {
        final args =
            codec.decodeMessage(message) as List<Object?>? ?? const <Object?>[];
        asked.add([method, ...args]);
        return codec.encodeMessage(<Object?>[reply(args)]);
      });
    }

    Future<void> notice(String event, List<Object?> args) async {
      await messenger.handlePlatformMessage(
        '$events.$event',
        GitEvents.pigeonChannelCodec.encodeMessage(args),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
    }

    GitExitMessage exitOf(
      int runId, {
      int? exitCode = 0,
      String? failure,
      int records = 0,
      bool truncated = false,
    }) => GitExitMessage(
      runId: runId,
      operation: 'status',
      exitCode: exitCode,
      failure: failure,
      stderr: '',
      records: records,
      chars: records * 5,
      truncated: truncated,
      elapsedMs: 12,
    );

    setUp(() => asked = []);

    tearDown(() {
      for (final method in ['run', 'stop']) {
        messenger.setMockMessageHandler('$prefix.$method', null);
      }
    });

    test(
      'runs a command by its project, and hears its records and exit',
      () async {
        answer('run', (args) => GitStartMessage());
        final host = PigeonGitHost();
        final ran = host.run(
          const GitInvocation(
            'status',
            ['--branch'],
            project: 'demo',
            maxRecords: 100,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        final request = asked.single[1]! as GitRunMessage;
        expect(request.project, 'demo');
        expect(request.operation, 'status');
        expect(request.arguments, ['--branch']);
        expect(request.maxRecords, 100);
        await notice('output', [
          request.runId,
          <String>['# branch.head main'],
        ]);
        await notice('output', [
          request.runId,
          <String>['? a.txt'],
        ]);
        await notice('exited', [exitOf(request.runId, records: 2)]);
        final outcome = (await ran).orThrow;
        expect(outcome.records, ['# branch.head main', '? a.txt']);
        expect(outcome.exitCode, 0);
        expect(outcome.ok, isTrue);
        expect(outcome.recordCount, 2);
        await host.dispose();
      },
    );

    test("a run's events may come before the host's answer", () async {
      final host = PigeonGitHost();
      final answered = Completer<void>();
      messenger.setMockMessageHandler('$prefix.run', (message) async {
        final args = codec.decodeMessage(message)! as List<Object?>;
        final request = args.single! as GitRunMessage;
        asked.add(['run', request]);
        // The exit first, then the answer.
        await notice('output', [
          request.runId,
          <String>['early'],
        ]);
        await notice('exited', [exitOf(request.runId, records: 1)]);
        answered.complete();
        return codec.encodeMessage(<Object?>[GitStartMessage()]);
      });
      final outcome = (await host.run(
        const GitInvocation('status', [], project: 'demo'),
      )).orThrow;
      expect(answered.isCompleted, isTrue);
      expect(outcome.records, ['early']);
      await host.dispose();
    });

    test('records go to a listener as they come, when one is given', () async {
      answer('run', (args) => GitStartMessage());
      final host = PigeonGitHost();
      final batches = <List<String>>[];
      final progress = <(String, bool)>[];
      final ran = host.run(
        const GitInvocation('log', [], project: 'demo'),
        onRecords: batches.add,
        onProgress: (text, closing) => progress.add((text, closing)),
      );
      await Future<void>.delayed(Duration.zero);
      final runId = (asked.single[1]! as GitRunMessage).runId;
      await notice('output', [
        runId,
        <String>['a', 'b'],
      ]);
      await notice('progress', [runId, 'Counting: 1', false]);
      await notice('progress', [runId, 'Counting: 2, done.', true]);
      await notice('exited', [exitOf(runId, records: 2)]);
      final outcome = (await ran).orThrow;
      expect(batches, [
        ['a', 'b'],
      ]);
      expect(outcome.records, isEmpty);
      expect(progress, [('Counting: 1', false), ('Counting: 2, done.', true)]);
      await host.dispose();
    });

    test("the host's refusal, and its end of a run, are failures", () async {
      answer(
        'run',
        (args) => GitStartMessage(
          failure: 'busy',
          detail: 'another change to this repository is running',
        ),
      );
      final host = PigeonGitHost();
      final refused = await host.run(
        const GitInvocation('add', ['-A'], project: 'demo'),
      );
      expect(refused, _fails(GitProblem.busy));
      expect(
        (refused.failureOrNull! as GitFailure).detail,
        'another change to this repository is running',
      );

      answer('run', (args) => GitStartMessage());
      final ran = host.run(const GitInvocation('status', [], project: 'demo'));
      await Future<void>.delayed(Duration.zero);
      final runId = (asked.last[1]! as GitRunMessage).runId;
      await notice('exited', [
        exitOf(runId, exitCode: null, failure: 'timed_out'),
      ]);
      expect(await ran, _fails(GitProblem.timedOut));

      // Ended at the cap: a beginning, not a failure.
      final capped = host.run(
        const GitInvocation('status', [], project: 'demo'),
      );
      await Future<void>.delayed(Duration.zero);
      final cappedId = (asked.last[1]! as GitRunMessage).runId;
      await notice('exited', [
        exitOf(cappedId, exitCode: null, truncated: true),
      ]);
      final outcome = (await capped).orThrow;
      expect(outcome.ok, isTrue);
      expect(outcome.truncated, isTrue);
      await host.dispose();
    });

    test('a stop asked for reaches the host', () async {
      answer('run', (args) => GitStartMessage());
      answer('stop', (args) => true);
      final host = PigeonGitHost();
      final stop = Completer<void>();
      final ran = host.run(
        const GitInvocation('status', [], project: 'demo'),
        stop: stop.future,
      );
      await Future<void>.delayed(Duration.zero);
      final runId = (asked.single[1]! as GitRunMessage).runId;
      stop.complete();
      await Future<void>.delayed(Duration.zero);
      expect(asked.last, ['stop', runId]);
      await notice('exited', [
        exitOf(runId, exitCode: null, failure: 'stopped'),
      ]);
      expect(await ran, _fails(GitProblem.stopped));
      await host.dispose();
    });

    test('without a host every run fails as unavailable, and a disposed '
        'client runs nothing', () async {
      final host = PigeonGitHost();
      expect(
        await host.run(const GitInvocation('status', [], project: 'demo')),
        _fails(GitProblem.unavailable),
      );
      answer('run', (args) => GitStartMessage());
      final pending = host.run(
        const GitInvocation('status', [], project: 'demo'),
      );
      await Future<void>.delayed(Duration.zero);
      await host.dispose();
      expect(await pending, _fails(GitProblem.unavailable));
      expect(
        await host.run(const GitInvocation('status', [], project: 'demo')),
        _fails(GitProblem.unavailable),
      );
    });
  });

  test('the honest fake: no git here, and it says so', () async {
    final git = FakeGitService();
    expect(git.available, isFalse);
    expect(await git.status('demo'), _fails(GitProblem.unavailable));
    expect(await git.identity(), _fails(GitProblem.unavailable));
    expect(await git.commit('demo', 'x'), _fails(GitProblem.unavailable));
  });
}
