/// The backup switch in Settings → Privacy (Phase 3 W1, ADR-0012): off by
/// default; what the host reports, and changes that wait for the host to
/// save them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/logging/logger.dart';
import '../services/platform/backup_channel.dart';
import 'providers.dart';

final class BackupState {
  const BackupState({
    this.status,
    this.failure,
    this.busy = false,
    this.changeFailed = false,
  });

  /// What the host last reported; null until it answered.
  final BackupStatus? status;

  /// Why the last read or change failed, if it did.
  final Failure? failure;

  /// Whether [failure] is a change the host did not save (else a read).
  final bool changeFailed;

  /// A change is on its way to the host.
  final bool busy;

  bool get loading => status == null && failure == null;
  bool get available => status?.available ?? false;
  bool get enabled => status?.enabled ?? false;
}

final class BackupController extends Notifier<BackupState> {
  @override
  BackupState build() => const BackupState();

  /// Reads the switch and Android's last pass from the host.
  Future<void> refresh() async {
    final result = await ref.read(backupServiceProvider).status();
    if (!ref.mounted) {
      return;
    }
    state = switch (result) {
      Ok<BackupStatus>(:final value) => BackupState(status: value),
      Err<BackupStatus>(:final failure) => BackupState(
        status: state.status,
        failure: failure,
      ),
    };
  }

  /// Turns Android's backup on or off. True once the host saved it; the
  /// switch shows the host's answer, never only the request.
  Future<bool> setEnabled(bool enabled) async {
    if (state.busy) {
      return false;
    }
    state = BackupState(status: state.status, busy: true);
    final result = await ref
        .read(backupServiceProvider)
        .setEnabled(enabled: enabled);
    if (!ref.mounted) {
      return result.isOk;
    }
    switch (result) {
      case Ok<BackupStatus>(:final value):
        state = BackupState(status: value);
        appLogger.info(
          'backup',
          'switch_set',
          fields: {'enabled': value.enabled, 'available': value.available},
        );
        return value.available && value.enabled == enabled;
      case Err<BackupStatus>(:final failure):
        state = BackupState(
          status: state.status,
          failure: failure,
          changeFailed: true,
        );
        appLogger.warn(
          'backup',
          'switch_failed',
          fields: {'enabled': enabled, 'error': failure.message},
        );
        return false;
    }
  }
}

final backupControllerProvider =
    NotifierProvider<BackupController, BackupState>(BackupController.new);
