/// What a remote run asks the user (Phase 7 W3, PHASE_7_PLAN W3): a token
/// for a host over HTTPS, with *Remember*, or whether to trust an SSH host
/// seen for the first time, by its key's fingerprint.
///
/// [GitCredentialPrompts] sits above every screen (app.dart) and hears the
/// Git host's questions wherever the user is; each is answered once, and a
/// question its run no longer waits for closes. A stored token a host
/// refused is removed, and said.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers.dart';
import '../../core/git/git_models.dart';
import '../../core/logging/logger.dart';
import '../../design_system/components/dialogs.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/icons.dart';

class GitCredentialPrompts extends ConsumerStatefulWidget {
  const GitCredentialPrompts({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  /// The app's navigator, whose context shows the dialogs.
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<GitCredentialPrompts> createState() =>
      _GitCredentialPromptsState();
}

class _GitCredentialPromptsState extends ConsumerState<GitCredentialPrompts> {
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Prompts withdrawn while their dialog shows: each dialog listens.
  final StreamController<int> _withdrawn = StreamController<int>.broadcast();

  @override
  void initState() {
    super.initState();
    final git = ref.read(gitServiceProvider);
    if (!git.available) {
      return;
    }
    _subscriptions
      ..add(git.credentialPrompts.listen(_ask))
      ..add(git.withdrawnPrompts.listen(_withdrawn.add))
      ..add(git.rejectedCredentials.listen(_rejected));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_withdrawn.close());
    super.dispose();
  }

  Future<void> _ask(GitCredentialPrompt prompt) async {
    final git = ref.read(gitServiceProvider);
    final context = widget.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      await git.answerCredential(GitCredentialAnswer.declined(prompt.id));
      return;
    }
    final answer = await showDialog<GitCredentialAnswer>(
      context: context,
      barrierDismissible: false,
      builder: (context) => switch (prompt.kind) {
        GitPromptKind.https => GitCredentialDialog(
          prompt: prompt,
          withdrawn: _withdrawn.stream,
        ),
        GitPromptKind.hostKey => GitHostKeyDialog(
          prompt: prompt,
          withdrawn: _withdrawn.stream,
        ),
      },
    );
    appLogger.info(
      'git',
      'credential_answered',
      fields: {
        'kind': prompt.kind.code,
        'accepted': '${answer?.accepted ?? false}',
      },
    );
    await git.answerCredential(
      answer ?? GitCredentialAnswer.declined(prompt.id),
    );
  }

  void _rejected(GitCredentialRejected rejected) {
    final context = widget.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          '${rejected.host} refused the token stored for '
          '${rejected.username}, so it was removed.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Closes [context]'s dialog, declining, when its prompt is withdrawn.
StreamSubscription<int> _closeWhenWithdrawn(
  BuildContext context,
  GitCredentialPrompt prompt,
  Stream<int> withdrawn,
) => withdrawn.listen((id) {
  if (id == prompt.id && context.mounted) {
    Navigator.of(context).pop(GitCredentialAnswer.declined(prompt.id));
  }
});

/// A user name and a token for [GitCredentialPrompt.host], and *Remember*.
class GitCredentialDialog extends StatefulWidget {
  const GitCredentialDialog({
    super.key,
    required this.prompt,
    required this.withdrawn,
  });

  final GitCredentialPrompt prompt;
  final Stream<int> withdrawn;

  @override
  State<GitCredentialDialog> createState() => _GitCredentialDialogState();
}

class _GitCredentialDialogState extends State<GitCredentialDialog> {
  late final TextEditingController _user = TextEditingController(
    text: widget.prompt.username ?? '',
  );
  final TextEditingController _token = TextEditingController();
  late final StreamSubscription<int> _withdrawal;
  bool _remember = true;
  bool _shown = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _withdrawal = _closeWhenWithdrawn(context, widget.prompt, widget.withdrawn);
  }

  @override
  void dispose() {
    unawaited(_withdrawal.cancel());
    _user.dispose();
    _token.clear();
    _token.dispose();
    super.dispose();
  }

  void _submit() {
    final user = _user.text.trim();
    final token = _token.text.trim();
    String? problem;
    if (user.isEmpty) {
      problem = 'Enter the user name.';
    } else if (token.isEmpty) {
      problem = 'Enter the token.';
    } else if ('$user$token'.contains(RegExp(r'[\r\n\x00]'))) {
      problem = 'A user name and a token are one line each.';
    }
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop(
      GitCredentialAnswer(
        id: widget.prompt.id,
        accepted: true,
        username: user,
        secret: token,
        remember: _remember,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final host = widget.prompt.host;
    return PopScope<Object?>(
      canPop: false,
      child: CfAlertDialog(
        key: const ValueKey('git_credential_dialog'),
        title: Text('Sign in to $host'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$host asks who you are. Use a personal access token: most '
              'hosts no longer take a password here.',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('git_credential_user'),
              controller: _user,
              readOnly: widget.prompt.username != null,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: widget.prompt.username == null,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'User name'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('git_credential_token'),
              controller: _token,
              autofocus: widget.prompt.username != null,
              obscureText: !_shown,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Token',
                errorText: _problem,
                errorMaxLines: 2,
                suffixIcon: IconButton(
                  key: const ValueKey('git_credential_show'),
                  tooltip: _shown ? 'Hide the token' : 'Show the token',
                  icon: Icon(_shown ? CfIcons.visibilityOff : CfIcons.visibility),
                  onPressed: () => setState(() => _shown = !_shown),
                ),
              ),
              onChanged: (_) {
                if (_problem != null) {
                  setState(() => _problem = null);
                }
              },
              onSubmitted: (_) => _submit(),
            ),
            CheckboxListTile(
              key: const ValueKey('git_credential_remember'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Remember on this device'),
              subtitle: const Text(
                'Kept encrypted with a key in Android\'s Keystore, never in '
                'a backup. Settings, Source control lists it.',
              ),
              value: _remember,
              onChanged: (value) => setState(() => _remember = value ?? false),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('git_credential_cancel'),
            onPressed: () => Navigator.of(
              context,
            ).pop(GitCredentialAnswer.declined(widget.prompt.id)),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('git_credential_confirm'),
            onPressed: _submit,
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
  }
}

/// Whether to trust an SSH host seen for the first time, by its key.
class GitHostKeyDialog extends StatefulWidget {
  const GitHostKeyDialog({
    super.key,
    required this.prompt,
    required this.withdrawn,
  });

  final GitCredentialPrompt prompt;
  final Stream<int> withdrawn;

  @override
  State<GitHostKeyDialog> createState() => _GitHostKeyDialogState();
}

class _GitHostKeyDialogState extends State<GitHostKeyDialog> {
  late final StreamSubscription<int> _withdrawal;

  @override
  void initState() {
    super.initState();
    _withdrawal = _closeWhenWithdrawn(context, widget.prompt, widget.withdrawn);
  }

  @override
  void dispose() {
    unawaited(_withdrawal.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final prompt = widget.prompt;
    final type = prompt.keyType ?? 'SSH';
    final fingerprint = prompt.fingerprint ?? '';
    final published = knownHostKeys[prompt.host];
    final publishedHere = published?[type];
    final (verdict, verdictColor) = switch (publishedHere) {
      null when published == null => (
        'Check it against the fingerprint ${prompt.host} publishes before '
            'trusting it.',
        colors.textSecondary,
      ),
      null => (
        '${prompt.host} publishes no $type key that CodeForge knows. Check '
            'it before trusting it.',
        colors.warning,
      ),
      final expected when expected == fingerprint => (
        'This is the key ${prompt.host} publishes.',
        colors.success,
      ),
      _ => (
        'This is NOT the key ${prompt.host} publishes. Do not trust it.',
        colors.danger,
      ),
    };
    return PopScope<Object?>(
      canPop: false,
      child: CfAlertDialog(
        key: const ValueKey('git_host_key_dialog'),
        title: Text('Trust ${prompt.host}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'This is the first SSH connection to ${prompt.host}. Its $type '
              'key\'s fingerprint is:',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SelectableText(
              fingerprint,
              key: const ValueKey('git_host_key_fingerprint'),
              style: textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Text(
              verdict,
              key: const ValueKey('git_host_key_verdict'),
              style: textTheme.bodySmall?.copyWith(color: verdictColor),
            ),
            const SizedBox(height: 8),
            Text(
              'Once trusted, it is kept in the runtime\'s known_hosts, which '
              'the terminal\'s ssh shares.',
              style: textTheme.labelSmall?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('git_host_key_cancel'),
            onPressed: () =>
                Navigator.of(context).pop(GitCredentialAnswer.declined(prompt.id)),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('git_host_key_trust'),
            onPressed: () => Navigator.of(
              context,
            ).pop(GitCredentialAnswer(id: prompt.id, accepted: true)),
            child: const Text('Trust'),
          ),
        ],
      ),
    );
  }
}
