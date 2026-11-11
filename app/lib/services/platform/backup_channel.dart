/// Android's backup switch and what Android last did with it (Phase 3 W1,
/// ADR-0012), over the `dev.codeforge/backup` channel (MainActivity,
/// BackupSwitch.kt). Off unless the user turns it on in Settings → Privacy.
/// It stays a plain channel: Phase 3 W2's Pigeon API is the storage
/// broker's alone.
library;

import 'package:flutter/services.dart';

import '../../core/errors/failure.dart';

/// The switch, and Android's last backup pass as the agent recorded it.
final class BackupStatus {
  const BackupStatus({
    required this.available,
    this.enabled = false,
    this.lastRunAt,
    this.lastRunKind,
    this.lastRunEncrypted = false,
    this.lastRunContent,
    this.quotaExceededAt,
    this.quotaBackupBytes = 0,
    this.quotaBytes = 0,
  });

  /// What the channel reports (BackupSwitch.status); 0 means never.
  factory BackupStatus.fromMap(Map<Object?, Object?> map) {
    DateTime? time(Object? millis) => millis is int && millis > 0
        ? DateTime.fromMillisecondsSinceEpoch(millis)
        : null;
    int number(Object? value) => value is int ? value : 0;
    return BackupStatus(
      available: true,
      enabled: map['enabled'] == true,
      lastRunAt: time(map['lastRunAt']),
      lastRunKind: map['lastRunKind'] as String?,
      lastRunEncrypted: map['lastRunEncrypted'] == true,
      lastRunContent: map['lastRunContent'] as String?,
      quotaExceededAt: time(map['quotaExceededAt']),
      quotaBackupBytes: number(map['quotaBackupBytes']),
      quotaBytes: number(map['quotaBytes']),
    );
  }

  /// Where there is no Android backup to ask: no host, as under
  /// `flutter test`.
  static const BackupStatus unavailable = BackupStatus(available: false);

  final bool available;

  /// Whether Android may back up the projects, the database and the
  /// settings; off by default.
  final bool enabled;

  /// When the agent last ran, for a backup or a device transfer.
  final DateTime? lastRunAt;

  /// 'cloud' or 'device' (a device-to-device transfer).
  final String? lastRunKind;

  /// Whether that pass was end-to-end encrypted.
  final bool lastRunEncrypted;

  /// What it wrote: 'everything'; 'switch', only the switch itself (off,
  /// after a backup with everything); or 'nothing' (off, and never a
  /// backup with everything: Android declines the empty backup and keeps
  /// none).
  final String? lastRunContent;

  /// When Android last refused a backup as too large, and the sizes.
  final DateTime? quotaExceededAt;
  final int quotaBackupBytes;
  final int quotaBytes;

  /// Whether the latest pass Android reported was refused as too large.
  bool get overQuota {
    final refused = quotaExceededAt;
    if (refused == null) {
      return false;
    }
    final ran = lastRunAt;
    return ran == null || !refused.isBefore(ran);
  }
}

/// The backup switch, behind a contract so tests can fake it.
abstract interface class BackupService {
  /// The switch and the last pass; [BackupStatus.unavailable] without a
  /// host to ask.
  Future<Result<BackupStatus>> status();

  /// Sets the switch, on disk before it answers, and tells Android a backup
  /// is due. The new status, or why the switch was not saved.
  Future<Result<BackupStatus>> setEnabled({required bool enabled});
}

/// [BackupService] over the platform channel.
final class ChannelBackupService implements BackupService {
  const ChannelBackupService();

  static const MethodChannel _channel = MethodChannel('dev.codeforge/backup');

  @override
  Future<Result<BackupStatus>> status() => _call('status');

  @override
  Future<Result<BackupStatus>> setEnabled({required bool enabled}) =>
      _call('setEnabled', {'enabled': enabled});

  Future<Result<BackupStatus>> _call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>(
        method,
        arguments,
      );
      if (map == null) {
        return const Err(StorageFailure('The backup state was not reported.'));
      }
      return Ok(BackupStatus.fromMap(map));
    } on MissingPluginException {
      return const Ok(BackupStatus.unavailable);
    } on PlatformException catch (error) {
      return Err(
        StorageFailure(
          error.message ?? 'The backup switch did not answer.',
          cause: error,
        ),
      );
    }
  }
}
