/// The backup switch without a host (Phase 3 W1): it keeps the switch in
/// memory, answers like BackupSwitch.kt, and can fail or be unavailable.
library;

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/platform/backup_channel.dart';

final class FakeBackupService implements BackupService {
  FakeBackupService({BackupStatus? status})
    : current = status ?? const BackupStatus(available: true);

  /// What [status] reports; [setEnabled] changes its switch.
  BackupStatus current;

  /// Fails the next [setEnabled] with this, as a host that could not save.
  Failure? failNextSet;

  /// Fails the next [status] with this, as a host that did not answer.
  Failure? failNextStatus;

  /// Every value [setEnabled] was asked for, in order.
  final List<bool> requests = [];

  @override
  Future<Result<BackupStatus>> status() async {
    final failure = failNextStatus;
    if (failure != null) {
      failNextStatus = null;
      return Err(failure);
    }
    return Ok(current);
  }

  @override
  Future<Result<BackupStatus>> setEnabled({required bool enabled}) async {
    requests.add(enabled);
    final failure = failNextSet;
    if (failure != null) {
      failNextSet = null;
      return Err(failure);
    }
    if (!current.available) {
      return Ok(current);
    }
    current = BackupStatus(
      available: true,
      enabled: enabled,
      lastRunAt: current.lastRunAt,
      lastRunKind: current.lastRunKind,
      lastRunEncrypted: current.lastRunEncrypted,
      lastRunContent: current.lastRunContent,
      quotaExceededAt: current.quotaExceededAt,
      quotaBackupBytes: current.quotaBackupBytes,
      quotaBytes: current.quotaBytes,
    );
    return Ok(current);
  }
}
