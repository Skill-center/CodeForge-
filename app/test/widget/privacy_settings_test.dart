/// Settings → Privacy (Phase 3 W1, ADR-0012, gate G6): Android's backup is
/// off by default, says what it copies, where and on what terms, changes
/// only through the host, and reads as one switch to a screen reader.
library;

import 'package:codeforge/application/backup_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/features/settings/privacy_section.dart';
import 'package:codeforge/services/platform/backup_channel.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backup_service.dart';
import 'test_harness.dart';

const ValueKey<String> _row = ValueKey('settings_backup');

Finder get _switch =>
    find.descendant(of: find.byKey(_row), matching: find.byType(Switch));

Future<TestHarness> _pumpSettings(
  WidgetTester tester, {
  FakeBackupService? backup,
}) async {
  setSurface(tester, 412, 915);
  final harness = TestHarness(
    shell: const ShellState(lastRoute: '/settings'),
    backup: backup,
  );
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(_row));
  await tester.pumpAndSettle();
  return harness;
}

String _subtitle(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: find.byKey(_row), matching: find.byType(Text)),
    )
    .map((text) => text.data)
    .last!;

void main() {
  testWidgets('backup is off by default and says what it copies', (
    tester,
  ) async {
    final harness = await _pumpSettings(tester);
    expect(find.text('PRIVACY'), findsOneWidget);
    expect(find.text('Back up with Android'), findsOneWidget);
    expect(tester.widget<Switch>(_switch).value, isFalse);
    expect(_subtitle(tester), 'Off');
    expect(harness.backup.requests, isEmpty);

    for (final term in [
      'projects, their unsaved changes and your settings',
      'Google Drive',
      'Android 9 and later when the phone has a screen lock',
      '25 MB',
      'shared storage',
      'the logs',
      'holds only this setting',
    ]) {
      expect(backupExplanation, contains(term));
    }
    expect(find.text(backupExplanation), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('the switch changes only through the host', (tester) async {
    final harness = await _pumpSettings(tester);
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    expect(harness.backup.requests, [true]);
    expect(harness.backup.current.enabled, isTrue);
    expect(tester.widget<Switch>(_switch).value, isTrue);
    expect(_subtitle(tester), "On · waiting for Android's next backup");

    // The row itself toggles too, like any settings switch row.
    await tester.tap(find.text('Back up with Android'));
    await tester.pumpAndSettle();
    expect(harness.backup.requests, [true, false]);
    expect(tester.widget<Switch>(_switch).value, isFalse);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('a host that did not save leaves the switch as it was', (
    tester,
  ) async {
    final backup = FakeBackupService()
      ..failNextSet = const StorageFailure('The backup switch was not saved.');
    await _pumpSettings(tester, backup: backup);
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    expect(backup.requests, [true]);
    expect(tester.widget<Switch>(_switch).value, isFalse);
    expect(find.text('The backup setting was not changed'), findsOneWidget);
    expect(_subtitle(tester), contains('Not changed'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('without a host the switch is off and cannot change', (
    tester,
  ) async {
    final backup = FakeBackupService(status: BackupStatus.unavailable);
    await _pumpSettings(tester, backup: backup);
    expect(tester.widget<Switch>(_switch).onChanged, isNull);
    expect(tester.widget<Switch>(_switch).value, isFalse);
    expect(_subtitle(tester), 'Not available on this device');
    await tester.tap(find.text('Back up with Android'));
    await tester.pumpAndSettle();
    expect(backup.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('the backup row is one switch node for a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpSettings(tester);
    final node = tester.getSemantics(_switch);
    expect(
      node,
      isSemantics(hasTapAction: true, hasToggledState: true, isToggled: false),
    );
    expect(node.getSemanticsData().label, contains('Back up with Android'));
    expect(node.getSemanticsData().label, contains('Off'));
    await tester.pump(const Duration(milliseconds: 500));
    semantics.dispose();
  });

  group('status line', () {
    final ran = DateTime(2026, 11, 10, 9, 5);
    BackupState on(BackupStatus status) => BackupState(status: status);

    test('before the host answered, and when it could not', () {
      expect(backupStatusLine(const BackupState()), 'Checking…');
      expect(
        backupStatusLine(const BackupState(failure: StorageFailure('x'))),
        'Could not read the backup setting',
      );
    });

    test('on: the last pass, its kind and encryption', () {
      expect(
        backupStatusLine(
          on(
            BackupStatus(
              available: true,
              enabled: true,
              lastRunAt: ran,
              lastRunKind: 'cloud',
              lastRunEncrypted: true,
              lastRunContent: 'everything',
            ),
          ),
        ),
        'On · last backup run 2026-11-10 09:05, end-to-end encrypted',
      );
      expect(
        backupStatusLine(
          on(
            BackupStatus(
              available: true,
              enabled: true,
              lastRunAt: ran,
              lastRunKind: 'device',
              lastRunContent: 'everything',
            ),
          ),
        ),
        'On · last copied to a new device 2026-11-10 09:05',
      );
      // Turned on after a pass that held only the switch.
      expect(
        backupStatusLine(
          on(
            BackupStatus(
              available: true,
              enabled: true,
              lastRunAt: ran,
              lastRunContent: 'switch',
            ),
          ),
        ),
        "On · waiting for Android's next backup",
      );
    });

    test('on: a backup Android refused as too large', () {
      expect(
        backupStatusLine(
          on(
            BackupStatus(
              available: true,
              enabled: true,
              lastRunAt: ran,
              lastRunContent: 'everything',
              quotaExceededAt: ran.add(const Duration(minutes: 1)),
              quotaBackupBytes: 30 * 1024 * 1024,
              quotaBytes: 25 * 1024 * 1024,
            ),
          ),
        ),
        'On · the last backup was too large (30.0 MB of 25.0 MB), so '
        'Android kept the one before',
      );
    });

    test('off by default: Android keeps no backup', () {
      // The agent wrote nothing, and Android declined the empty backup.
      expect(
        backupStatusLine(
          on(
            BackupStatus(
              available: true,
              lastRunAt: ran,
              lastRunContent: 'nothing',
            ),
          ),
        ),
        'Off',
      );
      expect(
        backupStatusLine(
          on(
            BackupStatus(
              available: true,
              enabled: true,
              lastRunAt: ran,
              lastRunContent: 'nothing',
            ),
          ),
        ),
        "On · waiting for Android's next backup",
      );
    });

    test('off: what the backup Android keeps holds', () {
      expect(
        backupStatusLine(
          on(
            BackupStatus(
              available: true,
              lastRunAt: ran,
              lastRunContent: 'everything',
            ),
          ),
        ),
        "Off · Android's next backup will hold only this setting",
      );
      expect(
        backupStatusLine(
          on(
            BackupStatus(
              available: true,
              lastRunAt: ran,
              lastRunContent: 'switch',
            ),
          ),
        ),
        'Off · the last backup held only this setting',
      );
    });

    test('the channel map, as BackupSwitch.status sends it', () {
      final status = BackupStatus.fromMap({
        'enabled': true,
        'lastRunAt': ran.millisecondsSinceEpoch,
        'lastRunKind': 'cloud',
        'lastRunEncrypted': false,
        'lastRunContent': 'everything',
        'quotaExceededAt': 0,
        'quotaBackupBytes': 0,
        'quotaBytes': 0,
      });
      expect(status.available, isTrue);
      expect(status.enabled, isTrue);
      expect(status.lastRunAt, ran);
      expect(status.quotaExceededAt, isNull);
      expect(status.overQuota, isFalse);
      expect(BackupStatus.fromMap(const {}).enabled, isFalse);
    });
  });
}
