/// Settings → Source control (Phase 7 W2, PHASE_7_PLAN W2): the identity
/// commits are made with, read from git once the runtime has started,
/// edited and saved; an email without an @ is not saved; without Git, the
/// screen says where Git runs.
library;

import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/design_system/components/buttons.dart';
import 'package:codeforge/features/settings/source_control_settings_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/scripted_git_service.dart';
import 'test_harness.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _openSourceControl(
  WidgetTester tester,
  TestHarness harness,
) async {
  setSurface(tester, 412, 915);
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  final tile = _key('settings_source_control');
  await tester.scrollUntilVisible(
    tile,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
  expect(find.byType(SourceControlSettingsScreen), findsOneWidget);
}

TextField _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(_key(key));

bool _saveEnabled(WidgetTester tester) =>
    tester.widget<CfButton>(_key('git_identity_save')).onPressed != null;

void main() {
  testWidgets('reads the identity once the runtime has started, and saves '
      'a new one', (tester) async {
    final git = ScriptedGitService()
      ..identityValue = const GitIdentity(name: 'Ada', email: 'ada@old.org');
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
      git: git,
    );
    await _openSourceControl(tester, harness);
    expect(_field(tester, 'git_identity_name').controller!.text, 'Ada');
    expect(
      _field(tester, 'git_identity_email').controller!.text,
      'ada@old.org',
    );
    expect(_saveEnabled(tester), isFalse);

    await tester.enterText(_key('git_identity_name'), 'Ada Lovelace');
    await tester.enterText(_key('git_identity_email'), 'ada@example.com');
    await tester.pumpAndSettle();
    expect(_saveEnabled(tester), isTrue);
    await tester.tap(_key('git_identity_save'));
    await tester.pumpAndSettle();
    expect(git.identitiesSet, const [
      GitIdentity(name: 'Ada Lovelace', email: 'ada@example.com'),
    ]);
    expect(find.text('Identity saved'), findsOneWidget);
    expect(_saveEnabled(tester), isFalse);
  });

  testWidgets('an email without an @ is not saved', (tester) async {
    final git = ScriptedGitService();
    await _openSourceControl(
      tester,
      TestHarness(
        shell: const ShellState(lastRoute: '/settings'),
        git: git,
      ),
    );
    await tester.enterText(_key('git_identity_name'), 'Ada');
    await tester.enterText(_key('git_identity_email'), 'not-an-email');
    await tester.pumpAndSettle();
    expect(find.text('An email address has an @.'), findsOneWidget);
    expect(_saveEnabled(tester), isFalse);
    expect(git.identitiesSet, isEmpty);
  });

  testWidgets('without Git it says where Git runs', (tester) async {
    await _openSourceControl(
      tester,
      TestHarness(shell: const ShellState(lastRoute: '/settings')),
    );
    expect(_key('git_identity_unavailable'), findsOneWidget);
    expect(
      find.text('Git runs on the Linux runtime, on Android.'),
      findsOneWidget,
    );
    expect(_key('git_identity_name'), findsNothing);
  });
}
