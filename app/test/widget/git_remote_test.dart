/// The remotes in the app (Phase 7 W3, gate G3): Home's Clone repository
/// (the URL checked, the name from the URL, progress and Stop, the project
/// opened), a host's question wherever the user is (a token with Remember,
/// a new SSH host by its fingerprint, a question withdrawn), a refused
/// stored token said, the palette's fetch, pull and push, and Settings'
/// accounts and SSH key.
library;

import 'dart:async';

import 'package:codeforge/application/commands.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/scripted_git_service.dart';
import 'test_harness.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

const GitCredentialPrompt _https = GitCredentialPrompt(
  id: 11,
  runId: 3,
  kind: GitPromptKind.https,
  host: 'github.com',
);

GitCredentialPrompt _hostKey(String fingerprint) => GitCredentialPrompt(
  id: 12,
  runId: 4,
  kind: GitPromptKind.hostKey,
  host: 'github.com',
  keyType: 'ED25519',
  fingerprint: fingerprint,
);

/// Runs palette command [id], as choosing it in the palette does.
void _runCommand(WidgetTester tester, String id) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(WorkbenchScreen)),
    listen: false,
  );
  container
      .read(commandRegistryProvider)
      .commands
      .firstWhere((c) => c.id == id)
      .onExecute();
}

Future<void> _home(WidgetTester tester, TestHarness harness) async {
  setSurface(tester, 412, 915);
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a token is asked for, typed, remembered and sent once', (
    tester,
  ) async {
    final git = ScriptedGitService();
    await _home(tester, TestHarness(git: git));
    git.ask(_https);
    await tester.pumpAndSettle();
    expect(_key('git_credential_dialog'), findsOneWidget);
    expect(find.text('Sign in to github.com'), findsOneWidget);
    // Nothing typed: it says what is missing, and sends nothing.
    await tester.tap(_key('git_credential_confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the user name.'), findsOneWidget);
    expect(git.answers, isEmpty);

    await tester.enterText(_key('git_credential_user'), 'ada');
    await tester.enterText(_key('git_credential_token'), 'ghp_secret');
    final token = tester.widget<TextField>(_key('git_credential_token'));
    expect(token.obscureText, isTrue);
    expect(token.enableIMEPersonalizedLearning, isFalse);
    await tester.tap(_key('git_credential_confirm'));
    await tester.pumpAndSettle();
    expect(_key('git_credential_dialog'), findsNothing);
    final answer = git.answers.single;
    expect(answer.id, 11);
    expect(answer.accepted, isTrue);
    expect(answer.username, 'ada');
    expect(answer.secret, 'ghp_secret');
    expect(answer.remember, isTrue, reason: 'Remember is on by default');
    expect(answer.toString(), isNot(contains('ghp_secret')));
  });

  testWidgets("the URL's user name stands, Remember can be left off, and "
      'Cancel declines', (tester) async {
    final git = ScriptedGitService();
    await _home(tester, TestHarness(git: git));
    git.ask(
      const GitCredentialPrompt(
        id: 21,
        runId: 3,
        kind: GitPromptKind.https,
        host: 'gitlab.com',
        username: 'bob',
      ),
    );
    await tester.pumpAndSettle();
    final user = tester.widget<TextField>(_key('git_credential_user'));
    expect(user.readOnly, isTrue);
    expect(user.controller!.text, 'bob');
    await tester.enterText(_key('git_credential_token'), 'glpat-x');
    await tester.tap(_key('git_credential_remember'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_credential_confirm'));
    await tester.pumpAndSettle();
    expect(git.answers.single.remember, isFalse);
    expect(git.answers.single.username, 'bob');

    git.ask(_https);
    await tester.pumpAndSettle();
    await tester.tap(_key('git_credential_cancel'));
    await tester.pumpAndSettle();
    expect(git.answers.last.id, 11);
    expect(git.answers.last.accepted, isFalse);
    expect(git.answers.last.secret, isNull);
  });

  testWidgets('a question its run gave up on closes, declined', (
    tester,
  ) async {
    final git = ScriptedGitService();
    await _home(tester, TestHarness(git: git));
    git.ask(_https);
    await tester.pumpAndSettle();
    expect(_key('git_credential_dialog'), findsOneWidget);
    git.withdraw(11);
    await tester.pumpAndSettle();
    expect(_key('git_credential_dialog'), findsNothing);
    expect(git.answers.single.accepted, isFalse);
  });

  testWidgets("a new SSH host shows its fingerprint and whether it is the "
      "host's published key", (tester) async {
    final git = ScriptedGitService();
    await _home(tester, TestHarness(git: git));
    git.ask(_hostKey('SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'));
    await tester.pumpAndSettle();
    expect(find.text('Trust github.com?'), findsOneWidget);
    expect(
      find.text('SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(_key('git_host_key_verdict')).data,
      'This is the key github.com publishes.',
    );
    await tester.tap(_key('git_host_key_trust'));
    await tester.pumpAndSettle();
    expect(git.answers.single.accepted, isTrue);

    git.ask(_hostKey('SHA256:somethingElse'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(_key('git_host_key_verdict')).data,
      contains('NOT the key'),
    );
    await tester.tap(_key('git_host_key_cancel'));
    await tester.pumpAndSettle();
    expect(git.answers.last.accepted, isFalse);
  });

  testWidgets('a stored token a host refused is said', (tester) async {
    final git = ScriptedGitService();
    await _home(tester, TestHarness(git: git));
    git.reject(
      const GitCredentialRejected(runId: 3, host: 'github.com', username: 'ada'),
    );
    await tester.pump();
    expect(
      find.text(
        'github.com refused the token stored for ada, so it was removed.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('Clone repository checks the URL, names the project after it, '
      'clones and opens it', (tester) async {
    final git = ScriptedGitService()
      ..remoteProgress = const [
        GitProgress(phase: 'Receiving objects', percent: 40, done: 4, total: 10),
      ];
    final harness = TestHarness(git: git);
    git.onOperation = (call) {
      if (call.startsWith('clone ')) {
        unawaited(
          harness.projects.create('Hello-World', seed: {'README.md': 'hi\n'}),
        );
      }
    };
    await _home(tester, harness);
    await tester.tap(_key('clone_repository'));
    await tester.pumpAndSettle();
    expect(_key('clone_dialog'), findsOneWidget);

    // A token in the URL is refused, with why.
    await tester.enterText(
      _key('clone_url'),
      'https://ghp_0123456789abcdefghijklmnopqrstuvwxyzAB@github.com/o/r.git',
    );
    await tester.tap(_key('clone_confirm'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This URL holds a token'), findsOneWidget);
    expect(git.calls, isEmpty);

    await tester.enterText(
      _key('clone_url'),
      'https://github.com/octocat/Hello-World.git',
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_key('clone_name')).controller!.text,
      'Hello-World',
    );
    git.holdOperations = Completer<void>();
    await tester.tap(_key('clone_confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(_key('git_progress_dialog'), findsOneWidget);
    expect(find.text('Cloning Hello-World'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('git_progress_text')).data,
      'Receiving objects 40% (4/10)',
    );
    git.holdOperations!.complete();
    await tester.pumpAndSettle();
    expect(git.calls, [
      'clone https://github.com/octocat/Hello-World.git Hello-World',
    ]);
    expect(_key('git_progress_dialog'), findsNothing);
    // The project opened.
    expect(find.byType(WorkbenchScreen), findsOneWidget);
  });

  testWidgets('Stop ends a clone, and nothing is kept', (tester) async {
    final git = ScriptedGitService();
    await _home(tester, TestHarness(git: git));
    await tester.tap(_key('clone_repository'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('clone_url'), 'git@github.com:o/r.git');
    await tester.pumpAndSettle();
    git.holdOperations = Completer<void>();
    await tester.tap(_key('clone_confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(_key('git_progress_stop'));
    await tester.pump();
    expect(
      tester.widget<Text>(_key('git_progress_text')).data,
      'Stopping…',
    );
    git.holdOperations!.complete();
    await tester.pumpAndSettle();
    expect(find.text('The clone was stopped. Nothing was kept.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('without Git, Clone says where Git runs', (tester) async {
    await _home(tester, TestHarness());
    await tester.tap(_key('clone_repository'));
    await tester.pumpAndSettle();
    expect(_key('clone_dialog'), findsNothing);
    expect(
      find.text('Git runs on the Linux runtime, on Android.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('Settings lists the accounts without their tokens, removes '
      'one, and makes, copies and deletes the SSH key', (tester) async {
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final git = ScriptedGitService()
      ..accountsValue = [
        GitAccount(
          kind: GitAccountKind.https,
          host: 'github.com',
          username: 'ada',
          updatedAt: DateTime.utc(2026, 11, 25),
        ),
      ];
    setSurface(tester, 412, 1600);
    await tester.pumpWidget(
      TestHarness(shell: const ShellState(lastRoute: '/settings'), git: git)
          .app(),
    );
    await tester.pumpAndSettle();
    final tile = _key('settings_source_control');
    await tester.scrollUntilVisible(
      tile,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final account = _key('git_account_github.com_ada');
    await tester.scrollUntilVisible(
      account,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(account, findsOneWidget);
    await tester.tap(_key('git_account_remove_github.com_ada'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_settings_confirm'));
    await tester.pumpAndSettle();
    expect(git.removedAccounts.single.host, 'github.com');
    expect(_key('git_accounts_empty'), findsOneWidget);

    await tester.scrollUntilVisible(
      _key('git_ssh_create'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(_key('git_ssh_create'));
    await tester.pumpAndSettle();
    expect(git.keysMade, ['codeforge@android']);
    await tester.scrollUntilVisible(
      _key('git_ssh_delete'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<SelectableText>(_key('git_ssh_public_key')).data,
      startsWith('ssh-ed25519 '),
    );
    await tester.tap(_key('git_ssh_copy'));
    await tester.pumpAndSettle();
    expect(copied.single, startsWith('ssh-ed25519 '));
    await tester.tap(_key('git_ssh_delete'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_settings_confirm'));
    await tester.pumpAndSettle();
    expect(git.sshKeyValue, isNull);
    expect(_key('git_ssh_create'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets("the palette's fetch, pull and push run on the open project", (
    tester,
  ) async {
    final git = ScriptedGitService(
      status: GitStatus(
        branch: GitBranchState(
          head: 'main',
          oid: 'a' * 40,
          upstream: 'origin/main',
          ahead: 1,
          behind: 0,
        ),
      ),
    );
    final harness = TestHarness(git: git);
    setSurface(tester, 1280, 800);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await openDemoWorkspace(tester);
    await tester.pumpAndSettle();
    for (final (command, done) in [
      ('git.fetch', 'Fetched.'),
      ('git.pull', 'Pulled.'),
      ('git.push', 'Pushed.'),
    ]) {
      _runCommand(tester, command);
      await tester.pumpAndSettle();
      expect(find.text(done), findsOneWidget, reason: command);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
    expect(git.calls, ['fetch', 'pull', 'push origin main']);
  });

}
