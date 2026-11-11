/// Home: the front door. Honest about what works today, one tap into the
/// demo workspace (gate G2), and since Phase 3 W2 a folder from the device
/// through Android's folder picker.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/settings_controller.dart';
import '../../application/shell_controller.dart';
import '../../application/workspace_switcher.dart';
import '../../core/errors/failure.dart';
import '../../core/files/workspace_location.dart';
import '../../core/logging/logger.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../services/contracts.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// A workspace is opening (the picker may be up): the buttons wait.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(shellControllerProvider.notifier).setLastRoute('/');
      final settings = ref.read(settingsControllerProvider);
      if (!settings.welcomeSeen) {
        _showWelcome();
      }
    });
  }

  void _showWelcome() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _WelcomeSheet(),
    );
  }

  Future<void> _openDemo() async {
    // The first time, this writes the demo project to the device.
    final result = await _whileBusy(
      () =>
          ref.read(workspaceSwitcherProvider).open(const DemoProjectLocation()),
    );
    if (!mounted || result == null) {
      return;
    }
    switch (result) {
      case Ok<WorkspaceRef>():
        ref.read(shellControllerProvider.notifier).markDemoWorkspaceOpened();
        appLogger.info('home', 'demo_workspace_opened');
        context.go('/workspace');
      case Err<WorkspaceRef>(:final failure):
        _tell(failure.message);
    }
  }

  /// Android's folder picker; the folder picked opens as the workspace.
  Future<void> _openFolder() async {
    final result = await _whileBusy(
      () => ref.read(workspaceSwitcherProvider).pickFolder(),
    );
    if (!mounted || result == null) {
      return;
    }
    switch (result) {
      case Ok<WorkspaceRef?>(:final value):
        if (value != null) {
          appLogger.info('home', 'folder_opened');
          context.go('/workspace');
        }
      case Err<WorkspaceRef?>(:final failure):
        _tell(failure.message);
    }
  }

  /// The folder opened last; when it is gone or no longer granted, says so.
  Future<void> _continueInFolder(FolderLocation folder) async {
    final result = await _whileBusy(
      () => ref.read(workspaceSwitcherProvider).open(folder),
    );
    if (!mounted || result == null) {
      return;
    }
    switch (result) {
      case Ok<WorkspaceRef>():
        context.go('/workspace');
      case Err<WorkspaceRef>(:final failure):
        _tell(failure.message);
    }
  }

  /// Runs [opening] unless another one is running (then null).
  Future<T?> _whileBusy<T>(Future<T> Function() opening) async {
    if (_busy) {
      return null;
    }
    setState(() => _busy = true);
    try {
      return await opening();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _tell(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final shell = ref.watch(shellControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.hardware, size: 20, color: colors.accentEmber),
            const SizedBox(width: CfSpacing.sm),
            const Text('CodeForge'),
          ],
        ),
        actions: [
          CfIconButton(
            key: const ValueKey('home_settings'),
            icon: Icons.settings_outlined,
            tooltip: 'Settings',
            onPressed: () => context.go('/settings'),
          ),
          const SizedBox(width: CfSpacing.sm),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(CfSpacing.lg),
          children: [
            const SizedBox(height: CfSpacing.lg),
            Text('Forge code,\nanywhere.', style: textTheme.displaySmall),
            const SizedBox(height: CfSpacing.sm),
            Text(
              'A mobile-first development environment. Phase 1 builds the '
              'workbench; editor, runtime and terminal follow.',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: CfSpacing.xl),
            Container(
              padding: const EdgeInsets.all(CfSpacing.lg),
              decoration: BoxDecoration(
                color: colors.surfacePanel,
                borderRadius: BorderRadius.circular(CfRadius.md),
                border: Border.all(color: colors.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 18,
                        color: colors.accentEmber,
                      ),
                      const SizedBox(width: CfSpacing.sm),
                      Expanded(
                        child: Text(
                          'Demo Workspace',
                          style: textTheme.titleMedium,
                        ),
                      ),
                      if (shell.demoWorkspaceOpened)
                        const CfStatusChip(label: 'recent'),
                    ],
                  ),
                  const SizedBox(height: CfSpacing.sm),
                  Text(
                    'A sample project — JavaScript, Python, Dart — kept on '
                    'this device. Open files in tabs, edit them and save.',
                    style: textTheme.bodySmall,
                  ),
                  const SizedBox(height: CfSpacing.lg),
                  CfButton(
                    key: const ValueKey('explore_demo'),
                    label: shell.demoWorkspaceOpened
                        ? 'Continue in Demo Workspace'
                        : 'Explore Demo Workspace',
                    icon: Icons.arrow_forward,
                    expanded: true,
                    onPressed: _busy ? null : _openDemo,
                  ),
                  if (shell.folder case final folder?) ...[
                    const SizedBox(height: CfSpacing.sm),
                    CfButton(
                      key: const ValueKey('continue_folder'),
                      label: 'Continue in ${folder.name}',
                      icon: Icons.folder_outlined,
                      variant: CfButtonVariant.ghost,
                      expanded: true,
                      onPressed: _busy ? null : () => _continueInFolder(folder),
                    ),
                  ],
                  const SizedBox(height: CfSpacing.sm),
                  CfButton(
                    key: const ValueKey('open_folder'),
                    label: 'Open Folder…',
                    icon: Icons.folder_open_outlined,
                    variant: CfButtonVariant.ghost,
                    expanded: true,
                    onPressed: _busy ? null : _openFolder,
                  ),
                  const SizedBox(height: CfSpacing.xs),
                  Text(
                    'A folder on this device, picked in Android\'s folder '
                    'picker: CodeForge can reach that folder and nothing '
                    'else.',
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: CfSpacing.lg),
            const CfBanner(
              message:
                  'Phase 1 shell: navigation, panels and settings are real. '
                  'Editing, terminal and runtimes are labeled previews.',
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomeSheet extends ConsumerWidget {
  const _WelcomeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    // Scrollable so large text scales never overflow on short landscape
    // screens (G3); the sheet still sizes to its content.
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(CfSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hardware, size: 24, color: colors.accentEmber),
                const SizedBox(width: CfSpacing.sm),
                Text('Welcome to CodeForge', style: textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: CfSpacing.lg),
            Text('What you can do today:', style: textTheme.bodyMedium),
            const SizedBox(height: CfSpacing.md),
            Text(
              '•  Edit and save real files in the demo workspace\n'
              '•  Switch themes, fonts and motion in Settings\n'
              '•  Your layout and open tabs come back after a restart',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: CfSpacing.lg),
            CfButton(
              key: const ValueKey('welcome_dismiss'),
              label: 'Start forging',
              expanded: true,
              onPressed: () {
                ref.read(settingsControllerProvider.notifier).setWelcomeSeen();
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}
