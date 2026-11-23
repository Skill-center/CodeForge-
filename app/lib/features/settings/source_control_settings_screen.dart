/// Settings → Source control (Phase 7 W2, PHASE_7_PLAN W2): the name and
/// email every commit is made with. They live in the Linux runtime's home
/// (`~/.gitconfig`), so the terminal's git commits as the same person.
/// Reading or writing them starts the runtime, as opening a workspace does.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers.dart';
import '../../application/runtime_controller.dart';
import '../../core/errors/failure.dart';
import '../../core/git/git_models.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';
import '../../services/runtime/runtime_service.dart';

/// The longest name or email git is given (the host refuses longer).
const int _maxIdentity = 256;

class SourceControlSettingsScreen extends ConsumerStatefulWidget {
  const SourceControlSettingsScreen({super.key});

  @override
  ConsumerState<SourceControlSettingsScreen> createState() =>
      _SourceControlSettingsScreenState();
}

class _SourceControlSettingsScreenState
    extends ConsumerState<SourceControlSettingsScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();

  /// What git has now.
  GitIdentity _saved = const GitIdentity();
  bool _loaded = false;
  bool _loading = false;
  bool _saving = false;

  /// Why the identity could not be read or saved; null when it was.
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(_edited);
    _email.addListener(_edited);
    if (ref.read(gitServiceProvider).available) {
      // The identity is read once the runtime is ready: now, or when it
      // has started.
      ref.listenManual<bool>(
        runtimeControllerProvider.select(
          (s) => s.state == RuntimeState.ready,
        ),
        (previous, ready) => _loadWhenReady(ready: ready),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final ready =
            ref.read(runtimeControllerProvider).state == RuntimeState.ready;
        _loadWhenReady(ready: ready);
        if (!ready) {
          unawaited(
            ref.read(runtimeControllerProvider.notifier).ensureStarted(),
          );
        }
      });
    }
  }

  void _loadWhenReady({required bool ready}) {
    if (ready && mounted && !_loaded && !_loading) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  void _edited() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await ref.read(gitServiceProvider).identity();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      switch (result) {
        case Ok<GitIdentity>(:final value):
          _loaded = true;
          _saved = value;
          _error = null;
          _name.text = value.name ?? '';
          _email.text = value.email ?? '';
        case Err<GitIdentity>(:final failure):
          _error = failure.message;
      }
    });
  }

  String? get _emailProblem {
    final email = _email.text.trim();
    if (email.isNotEmpty && !email.contains('@')) {
      return 'An email address has an @.';
    }
    return null;
  }

  bool get _changed =>
      _name.text.trim() != (_saved.name ?? '') ||
      _email.text.trim() != (_saved.email ?? '');

  Future<void> _save() async {
    final identity = GitIdentity(
      name: _name.text.trim(),
      email: _email.text.trim(),
    );
    setState(() => _saving = true);
    final result = await ref.read(gitServiceProvider).setIdentity(identity);
    if (!mounted) {
      return;
    }
    setState(() {
      _saving = false;
      switch (result) {
        case Ok<void>():
          _saved = GitIdentity(
            name: identity.name!.isEmpty ? null : identity.name,
            email: identity.email!.isEmpty ? null : identity.email,
          );
          _error = null;
        case Err<void>(:final failure):
          _error = failure.message;
      }
    });
    if (result.isOk) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Identity saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = ref.watch(gitServiceProvider).available;
    final ready = ref.watch(
      runtimeControllerProvider.select((s) => s.state == RuntimeState.ready),
    );
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final note = textTheme.bodyMedium?.copyWith(color: colors.textSecondary);
    final error = _error;
    final emailProblem = _emailProblem;
    final editable = available && _loaded && !_saving;
    return Scaffold(
      appBar: AppBar(
        leading: CfIconButton(
          icon: CfIcons.arrowBack,
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('Source control'),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            const CfSectionHeader('Identity'),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CfSpacing.lg,
                0,
                CfSpacing.lg,
                CfSpacing.md,
              ),
              child: Text(
                'Every commit records a name and an email. They are kept in '
                "the Linux runtime's home, in ~/.gitconfig, so git in the "
                'terminal commits as the same person.',
                style: note,
              ),
            ),
            if (!available)
              _Notice(
                key: const ValueKey('git_identity_unavailable'),
                text: 'Git runs on the Linux runtime, on Android.',
                style: note,
              )
            else ...[
              if (!_loaded && error == null)
                _Notice(
                  key: const ValueKey('git_identity_waiting'),
                  text: ready
                      ? 'Reading your identity…'
                      : 'Starting the Linux runtime…',
                  style: note,
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
                child: TextField(
                  key: const ValueKey('git_identity_name'),
                  controller: _name,
                  enabled: editable,
                  maxLength: _maxIdentity,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Ada Lovelace',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(height: CfSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
                child: TextField(
                  key: const ValueKey('git_identity_email'),
                  controller: _email,
                  enabled: editable,
                  maxLength: _maxIdentity,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    hintText: 'ada@example.com',
                    counterText: '',
                    errorText: emailProblem,
                  ),
                ),
              ),
              if (error != null)
                _Notice(
                  key: const ValueKey('git_identity_error'),
                  text: error,
                  style: note?.copyWith(color: colors.danger),
                ),
              Padding(
                padding: const EdgeInsets.all(CfSpacing.lg),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: CfButton(
                    key: const ValueKey('git_identity_save'),
                    label: _saving ? 'Saving…' : 'Save',
                    onPressed:
                        editable && _changed && emailProblem == null
                        ? () => unawaited(_save())
                        : null,
                  ),
                ),
              ),
              if (!_loaded && error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: CfSpacing.lg,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: CfButton(
                      key: const ValueKey('git_identity_retry'),
                      label: 'Try again',
                      variant: CfButtonVariant.tonal,
                      onPressed: ready ? () => unawaited(_load()) : null,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A line of text under the section's words.
class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      CfSpacing.lg,
      0,
      CfSpacing.lg,
      CfSpacing.md,
    ),
    child: Text(text, style: style),
  );
}
