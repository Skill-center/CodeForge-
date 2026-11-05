/// Home: the front door. Honest about Phase 1 capabilities, one tap into
/// the demo workspace (gate G2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/providers.dart';
import '../../application/settings_controller.dart';
import '../../application/shell_controller.dart';
import '../../core/errors/failure.dart';
import '../../core/logging/logger.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
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
    final files = ref.read(fileServiceProvider);
    final result = await files.openDemoWorkspace();
    if (result.isOk) {
      ref.read(shellControllerProvider.notifier).markDemoWorkspaceOpened();
      appLogger.info('home', 'demo_workspace_opened');
      if (mounted) {
        context.go('/workspace');
      }
    }
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
                    'A bundled sample project — JavaScript, Python, Dart. '
                    'Explore the full workbench layout with real tabs and '
                    'panels.',
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
                    onPressed: _openDemo,
                  ),
                  const SizedBox(height: CfSpacing.sm),
                  const CfButton(
                    key: ValueKey('open_folder_disabled'),
                    label: 'Open Folder…',
                    icon: Icons.folder_open_outlined,
                    variant: CfButtonVariant.ghost,
                    expanded: true,
                    onPressed: null,
                  ),
                  const SizedBox(height: CfSpacing.xs),
                  Text(
                    'Folder access (SAF) arrives in Phase 3.',
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.textDisabled,
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
            Text(
              'This is the Phase 1 foundation. What you can do today:',
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: CfSpacing.md),
            Text(
              '•  Explore the demo workspace with real tabs and panels\n'
              '•  Switch themes, fonts and motion in Settings\n'
              '•  Your layout is remembered across restarts',
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
