/// Settings → Source control's accounts and SSH key (Phase 7 W3,
/// PHASE_7_PLAN W3): the hosts and user names CodeForge keeps a token for,
/// never a token, each with *Remove*; and CodeForge's SSH key, made here,
/// its public half shown to copy into a host's settings.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers.dart';
import '../../core/errors/failure.dart';
import '../../core/git/git_models.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/dialogs.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';

/// The default name of a new key: who and where it is.
const String defaultSshKeyName = 'codeforge@android';

class GitAccountsSection extends ConsumerStatefulWidget {
  const GitAccountsSection({super.key, required this.ready});

  /// The Linux runtime is ready: the SSH key lives in its home.
  final bool ready;

  @override
  ConsumerState<GitAccountsSection> createState() => _GitAccountsSectionState();
}

class _GitAccountsSectionState extends ConsumerState<GitAccountsSection> {
  List<GitAccount>? _accounts;
  GitSshKey? _key;
  bool _keyLoaded = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAccounts());
    if (widget.ready) {
      unawaited(_loadKey());
    }
  }

  @override
  void didUpdateWidget(GitAccountsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready && !oldWidget.ready && !_keyLoaded) {
      unawaited(_loadKey());
    }
  }

  Future<void> _loadAccounts() async {
    final result = await ref.read(gitServiceProvider).accounts();
    if (!mounted) {
      return;
    }
    setState(() {
      switch (result) {
        case Ok<List<GitAccount>>(:final value):
          _accounts = [
            for (final account in value)
              if (account.kind == GitAccountKind.https) account,
          ];
        case Err<List<GitAccount>>(:final failure):
          _error = failure.message;
      }
    });
  }

  Future<void> _loadKey() async {
    final result = await ref.read(gitServiceProvider).sshKey();
    if (!mounted) {
      return;
    }
    setState(() {
      _keyLoaded = true;
      switch (result) {
        case Ok<GitSshKey?>(:final value):
          _key = value;
        case Err<GitSshKey?>(:final failure):
          _error = failure.message;
      }
    });
  }

  Future<void> _remove(GitAccount account) async {
    final confirmed = await _confirm(
      title: 'Remove the token for ${account.host}?',
      body:
          'CodeForge forgets the token for ${account.username} on '
          '${account.host}, and asks again the next time the host wants one. '
          'The token itself stays valid until you revoke it on the host.',
      action: 'Remove',
      key: const ValueKey('git_account_remove_confirm'),
    );
    if (!confirmed || !mounted) {
      return;
    }
    await _whileBusy(() async {
      final result = await ref.read(gitServiceProvider).removeAccount(account);
      if (result case Err<bool>(:final failure)) {
        _error = failure.message;
      }
      await _loadAccounts();
    });
  }

  Future<void> _createKey() async {
    if (_key != null) {
      final confirmed = await _confirm(
        title: 'Replace the SSH key?',
        body:
            'The current key is deleted. Hosts that know it refuse the new '
            'one until you add the new public key to their settings.',
        action: 'Replace',
        key: const ValueKey('git_ssh_replace_confirm'),
      );
      if (!confirmed || !mounted) {
        return;
      }
    }
    await _whileBusy(() async {
      final result = await ref
          .read(gitServiceProvider)
          .createSshKey(defaultSshKeyName);
      switch (result) {
        case Ok<GitSshKey>(:final value):
          _key = value;
          _error = null;
        case Err<GitSshKey>(:final failure):
          _error = failure.message;
      }
    });
  }

  Future<void> _deleteKey() async {
    final confirmed = await _confirm(
      title: 'Delete the SSH key?',
      body:
          'Hosts that know it can no longer be reached over SSH from this '
          'device until a new key is added to their settings.',
      action: 'Delete',
      key: const ValueKey('git_ssh_delete_confirm'),
    );
    if (!confirmed || !mounted) {
      return;
    }
    await _whileBusy(() async {
      final result = await ref.read(gitServiceProvider).deleteSshKey();
      switch (result) {
        case Ok<bool>():
          _key = null;
        case Err<bool>(:final failure):
          _error = failure.message;
      }
    });
  }

  Future<void> _copy(GitSshKey key) async {
    await Clipboard.setData(ClipboardData(text: key.publicKey));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Public key copied')),
    );
  }

  Future<void> _whileBusy(Future<void> Function() work) async {
    setState(() => _busy = true);
    try {
      await work();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    required Key key,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => CfAlertDialog(
        key: key,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: const ValueKey('git_settings_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('git_settings_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final note = textTheme.bodyMedium?.copyWith(color: colors.textSecondary);
    final accounts = _accounts;
    final key = _key;
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CfSectionHeader('Accounts'),
        _Padded(
          Text(
            'Tokens CodeForge keeps for hosts, encrypted with a key in '
            "Android's Keystore and never in a backup. Git gets one only "
            'when that host asks.',
            style: note,
          ),
        ),
        if (accounts == null)
          _Padded(Text('Reading…', style: note))
        else if (accounts.isEmpty)
          _Padded(
            Text(
              'None yet: CodeForge asks for a token the first time a host '
              'wants one, and keeps it when you choose Remember.',
              key: const ValueKey('git_accounts_empty'),
              style: note,
            ),
          )
        else
          for (final account in accounts)
            ListTile(
              key: ValueKey('git_account_${account.host}_${account.username}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: CfSpacing.lg,
              ),
              title: Text(account.host),
              subtitle: Text(account.username),
              trailing: CfIconButton(
                key: ValueKey(
                  'git_account_remove_${account.host}_${account.username}',
                ),
                icon: CfIcons.delete,
                tooltip: 'Remove the token for ${account.host}',
                onPressed: _busy ? null : () => unawaited(_remove(account)),
              ),
            ),
        const CfSectionHeader('SSH key'),
        _Padded(
          Text(
            'For SSH remotes (git@host:owner/repo.git). The key lives in the '
            "Linux runtime's home, encrypted with a passphrase only "
            "CodeForge's store holds. Add its public key to the host's "
            'settings.',
            style: note,
          ),
        ),
        if (!widget.ready)
          _Padded(Text('Starting the Linux runtime…', style: note))
        else if (!_keyLoaded)
          _Padded(Text('Reading…', style: note))
        else if (key == null)
          _Padded(
            Align(
              alignment: Alignment.centerLeft,
              child: CfButton(
                key: const ValueKey('git_ssh_create'),
                label: _busy ? 'Making the key…' : 'Create SSH key',
                icon: CfIcons.add,
                onPressed: _busy ? null : () => unawaited(_createKey()),
              ),
            ),
          )
        else ...[
          _Padded(
            SelectableText(
              key.publicKey,
              key: const ValueKey('git_ssh_public_key'),
              maxLines: 4,
              style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          _Padded(
            Text(
              key.fingerprint,
              key: const ValueKey('git_ssh_fingerprint'),
              style: note,
            ),
          ),
          _Padded(
            Wrap(
              spacing: CfSpacing.sm,
              runSpacing: CfSpacing.sm,
              children: [
                CfButton(
                  key: const ValueKey('git_ssh_copy'),
                  label: 'Copy public key',
                  icon: CfIcons.contentCopy,
                  variant: CfButtonVariant.tonal,
                  onPressed: () => unawaited(_copy(key)),
                ),
                CfButton(
                  key: const ValueKey('git_ssh_replace'),
                  label: 'Replace',
                  variant: CfButtonVariant.ghost,
                  onPressed: _busy ? null : () => unawaited(_createKey()),
                ),
                CfButton(
                  key: const ValueKey('git_ssh_delete'),
                  label: 'Delete',
                  variant: CfButtonVariant.ghost,
                  onPressed: _busy ? null : () => unawaited(_deleteKey()),
                ),
              ],
            ),
          ),
        ],
        if (error != null)
          _Padded(
            Text(
              error,
              key: const ValueKey('git_accounts_error'),
              style: note?.copyWith(color: colors.danger),
            ),
          ),
      ],
    );
  }
}

class _Padded extends StatelessWidget {
  const _Padded(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      CfSpacing.lg,
      0,
      CfSpacing.lg,
      CfSpacing.md,
    ),
    child: child,
  );
}
