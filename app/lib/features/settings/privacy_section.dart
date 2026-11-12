/// Settings → Privacy (Phase 3 W1, ADR-0012): Android's backup, the user's
/// choice, off by default, with what it copies, where, and on what terms.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/backup_controller.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';

/// What the switch's row says under its title.
String backupStatusLine(BackupState state) {
  final status = state.status;
  if (status == null) {
    return state.failure == null
        ? 'Checking…'
        : 'Could not read the backup setting';
  }
  if (!status.available) {
    return 'Not available on this device';
  }
  if (state.failure case final failure?) {
    return state.changeFailed
        ? 'Not changed: ${failure.message}'
        : 'Could not read the backup setting';
  }
  final ran = status.lastRunAt;
  if (status.enabled) {
    if (status.overQuota) {
      return 'On · the last backup was too large '
          '(${_mb(status.quotaBackupBytes)} of ${_mb(status.quotaBytes)}), '
          'so Android kept the one before';
    }
    if (ran == null || status.lastRunContent != 'everything') {
      return "On · waiting for Android's next backup";
    }
    // The agent sees its own pass, not the transport's verdict (only a
    // refusal as too large comes back), hence "run".
    final what = status.lastRunKind == 'device'
        ? 'last copied to a new device'
        : 'last backup run';
    final encrypted = status.lastRunEncrypted ? ', end-to-end encrypted' : '';
    return 'On · $what ${_when(ran)}$encrypted';
  }
  return switch (status.lastRunContent) {
    'everything' when ran != null =>
      "Off · Android's next backup will hold only this setting",
    'switch' when ran != null => 'Off · the last backup held only this setting',
    // Never backed up, or the agent wrote nothing: Android keeps no backup.
    _ => 'Off',
  };
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _when(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

/// What the explanation under the switch says.
const String backupExplanation =
    'When this is on, Android copies your projects, their unsaved changes '
    'and your settings to your Google Drive, about once a day while the '
    'phone is idle and on Wi-Fi, and brings them back when CodeForge is '
    'installed again or moved to a new phone. Android encrypts the copy '
    'end to end on Android 9 and later when the phone has a screen lock, '
    'and keeps at most 25 MB. Folders you open from shared storage are '
    "yours, not CodeForge's: they are never part of it, and neither are "
    'the logs. Turning this off replaces the copy with one that holds only '
    'this setting.';

class PrivacySection extends ConsumerStatefulWidget {
  const PrivacySection({super.key});

  @override
  ConsumerState<PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends ConsumerState<PrivacySection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(backupControllerProvider.notifier).refresh();
      }
    });
  }

  Future<void> _set(bool enabled) async {
    final saved = await ref
        .read(backupControllerProvider.notifier)
        .setEnabled(enabled);
    if (!mounted) {
      return;
    }
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The backup setting was not changed')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final backup = ref.watch(backupControllerProvider);
    final canChange = backup.available && !backup.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CfSectionHeader('Privacy'),
        CfSettingsTile(
          key: const ValueKey('settings_backup'),
          leading: const Icon(CfIcons.cloudUpload),
          title: 'Back up with Android',
          subtitle: backupStatusLine(backup),
          trailing: Switch(
            value: backup.enabled,
            onChanged: canChange ? _set : null,
          ),
          onTap: canChange ? () => _set(!backup.enabled) : null,
        ),
        Padding(
          key: const ValueKey('settings_backup_explanation'),
          padding: const EdgeInsets.fromLTRB(
            CfSpacing.lg,
            0,
            CfSpacing.lg,
            CfSpacing.md,
          ),
          child: Text(
            backupExplanation,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
