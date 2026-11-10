/// The backup switch's controller (Phase 3 W1, ADR-0012): off until the
/// host says otherwise, and the switch shows the host's answer, never only
/// the request.
library;

import 'package:codeforge/application/backup_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/features/settings/privacy_section.dart';
import 'package:codeforge/services/platform/backup_channel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backup_service.dart';

ProviderContainer _container(FakeBackupService backup) =>
    ProviderContainer.test(
      overrides: [backupServiceProvider.overrideWithValue(backup)],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('off and loading until the host answers', () async {
    final backup = FakeBackupService();
    final container = _container(backup);
    final initial = container.read(backupControllerProvider);
    expect(initial.loading, isTrue);
    expect(initial.enabled, isFalse);
    expect(initial.available, isFalse);

    await container.read(backupControllerProvider.notifier).refresh();
    final state = container.read(backupControllerProvider);
    expect(state.loading, isFalse);
    expect(state.available, isTrue);
    expect(state.enabled, isFalse);
    expect(backup.requests, isEmpty);
  });

  test('a saved change shows the host answer', () async {
    final backup = FakeBackupService();
    final container = _container(backup);
    final controller = container.read(backupControllerProvider.notifier);
    await controller.refresh();

    expect(await controller.setEnabled(true), isTrue);
    expect(container.read(backupControllerProvider).enabled, isTrue);
    expect(backup.current.enabled, isTrue);

    expect(await controller.setEnabled(false), isTrue);
    expect(container.read(backupControllerProvider).enabled, isFalse);
    expect(backup.requests, [true, false]);
  });

  test('a change the host did not save leaves the switch as it was', () async {
    final backup = FakeBackupService()
      ..failNextSet = const StorageFailure('The backup switch was not saved.');
    final container = _container(backup);
    final controller = container.read(backupControllerProvider.notifier);
    await controller.refresh();

    expect(await controller.setEnabled(true), isFalse);
    final state = container.read(backupControllerProvider);
    expect(state.enabled, isFalse);
    expect(state.busy, isFalse);
    expect(state.changeFailed, isTrue);
    expect(
      backupStatusLine(state),
      'Not changed: The backup switch was not saved.',
    );

    // The next change goes through and clears the failure.
    expect(await controller.setEnabled(true), isTrue);
    expect(container.read(backupControllerProvider).failure, isNull);
  });

  test('a read the host did not answer is not a change', () async {
    final backup = FakeBackupService()
      ..failNextStatus = const StorageFailure('No answer.');
    final container = _container(backup);
    final controller = container.read(backupControllerProvider.notifier);
    await controller.refresh();
    expect(
      backupStatusLine(container.read(backupControllerProvider)),
      'Could not read the backup setting',
    );

    // A known switch stays, and the line does not claim a refused change.
    await controller.refresh();
    expect(await controller.setEnabled(true), isTrue);
    backup.failNextStatus = const StorageFailure('No answer.');
    await controller.refresh();
    final state = container.read(backupControllerProvider);
    expect(state.enabled, isTrue);
    expect(state.changeFailed, isFalse);
    expect(backupStatusLine(state), 'Could not read the backup setting');
  });

  test('one change at a time', () async {
    final backup = FakeBackupService();
    final container = _container(backup);
    final controller = container.read(backupControllerProvider.notifier);
    await controller.refresh();

    final first = controller.setEnabled(true);
    expect(container.read(backupControllerProvider).busy, isTrue);
    expect(await controller.setEnabled(false), isFalse);
    expect(await first, isTrue);
    expect(backup.requests, [true]);
    expect(container.read(backupControllerProvider).enabled, isTrue);
  });

  test('without a host nothing changes', () async {
    final backup = FakeBackupService(status: BackupStatus.unavailable);
    final container = _container(backup);
    final controller = container.read(backupControllerProvider.notifier);
    await controller.refresh();
    expect(container.read(backupControllerProvider).available, isFalse);
    expect(await controller.setEnabled(true), isFalse);
    expect(container.read(backupControllerProvider).enabled, isFalse);
  });

  test('the channel service answers unavailable without a host', () async {
    const service = ChannelBackupService();
    final status = await service.status();
    expect(status.valueOrNull?.available, isFalse);
    final set = await service.setEnabled(enabled: true);
    expect(set.valueOrNull?.available, isFalse);
  });
}
