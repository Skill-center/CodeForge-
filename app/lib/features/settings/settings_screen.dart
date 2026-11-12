/// Settings root page. Every toggle here is real and persisted (G5); the
/// backup switch is the host's, which keeps it where Android's backup agent
/// can read it (ADR-0012).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/bench/large_test_files.dart';
import '../../application/settings_controller.dart';
import '../../application/shell_controller.dart';
import '../../core/editor/large_samples.dart';
import '../../core/errors/failure.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';
import 'privacy_section.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(shellControllerProvider.notifier).setLastRoute('/settings');
    });
  }

  Future<void> _createLargeFiles() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await ref.read(largeTestFilesProvider.notifier).create();
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (result) {
          Ok<int>(:final value) =>
            'Wrote ${_files(value)} to $largeTestFolder/',
          Err<int>(:final failure) => failure.message,
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final largeFiles = ref.watch(largeTestFilesProvider);
    // Nothing beneath a go()-reached top-level route: system back returns
    // home, matching the app-bar back button (G2).
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/');
      },
      child: Scaffold(
        appBar: AppBar(
          leading: CfIconButton(
            icon: CfIcons.arrowBack,
            tooltip: 'Back',
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
          ),
          title: const Text('Settings'),
        ),
        body: SafeArea(
          child: ListView(
            children: [
              const CfSectionHeader('Workspace'),
              CfSettingsTile(
                leading: const Icon(CfIcons.palette),
                title: 'Appearance',
                subtitle: 'Theme, editor font, motion, toolbar',
                trailing: const Icon(CfIcons.chevronRight, size: 18),
                onTap: () => context.go('/settings/appearance'),
              ),
              CfSettingsTile(
                key: const ValueKey('settings_reduced_motion'),
                leading: const Icon(CfIcons.motionPhotosOff),
                title: 'Reduced motion',
                subtitle: 'Minimize non-essential animation',
                trailing: Switch(
                  value: settings.reducedMotion,
                  onChanged: (value) => ref
                      .read(settingsControllerProvider.notifier)
                      .setReducedMotion(value),
                ),
                onTap: () => ref
                    .read(settingsControllerProvider.notifier)
                    .setReducedMotion(!settings.reducedMotion),
              ),
              const PrivacySection(),
              const CfSectionHeader('Coming in later phases'),
              const CfSettingsTile(
                leading: Icon(CfIcons.folder),
                title: 'Storage & folders',
                subtitle: 'Phase 3 — SAF workspace access',
                onTap: null,
              ),
              const CfSettingsTile(
                leading: Icon(CfIcons.memory),
                title: 'Linux runtime',
                subtitle: 'Phase 4 — install and health',
                onTap: null,
              ),
              const CfSettingsTile(
                leading: Icon(CfIcons.extension),
                title: 'Extensions',
                subtitle: 'Phase 7 — curated catalog',
                onTap: null,
              ),
              const CfSectionHeader('About'),
              CfSettingsTile(
                leading: const Icon(CfIcons.info),
                title: 'About CodeForge',
                subtitle: 'Version, licenses, diagnostics',
                trailing: const Icon(CfIcons.chevronRight, size: 18),
                onTap: () => context.go('/settings/about'),
              ),
              if (kDebugMode)
                CfSettingsTile(
                  key: const ValueKey('settings_gallery'),
                  leading: const Icon(CfIcons.designServices),
                  title: 'Component gallery',
                  subtitle: 'Debug only — Forge design system',
                  trailing: const Icon(CfIcons.chevronRight, size: 18),
                  onTap: () => context.go('/settings/gallery'),
                ),
              // Developer tools ship in debug and profile builds only (the
              // phone test build is a profile build).
              if (!kReleaseMode) ...[
                const CfSectionHeader('Developer'),
                CfSettingsTile(
                  key: const ValueKey('settings_editor_benchmark'),
                  leading: const Icon(CfIcons.speed),
                  title: 'Editor benchmark',
                  subtitle: 'CodeMirror 6 vs Monaco on this device',
                  trailing: const Icon(CfIcons.chevronRight, size: 18),
                  onTap: () => context.go('/settings/editor-benchmark'),
                ),
                CfSettingsTile(
                  key: const ValueKey('settings_frame_timing'),
                  leading: const Icon(CfIcons.timer),
                  title: 'Frame timing',
                  subtitle: 'Navigation frames against the 32 ms budget',
                  trailing: const Icon(CfIcons.chevronRight, size: 18),
                  onTap: () => context.go('/settings/frame-timing'),
                ),
                CfSettingsTile(
                  key: const ValueKey('settings_large_files'),
                  leading: const Icon(CfIcons.noteAdd),
                  title: 'Create large test files',
                  subtitle: largeTestFilesLine(largeFiles),
                  onTap: largeFiles.running ? null : _createLargeFiles,
                ),
              ],
              const SizedBox(height: CfSpacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the Developer action's row says under its title.
String largeTestFilesLine(LargeTestFilesState state) {
  if (state.running) {
    return 'Writing ${state.current ?? 'the files'}…';
  }
  if (state.failure case final failure?) {
    return 'Stopped after ${_files(state.written)}: ${failure.message}';
  }
  if (state.written > 0) {
    final mb = (state.bytes / (1024 * 1024)).toStringAsFixed(1);
    return 'Wrote ${_files(state.written)} ($mb MB) to $largeTestFolder/';
  }
  return "The large-file gate's ${largeSamples.length} files, 512 KiB to "
      '10 MiB, written to $largeTestFolder/ in the workspace';
}

String _files(int count) => count == 1 ? '1 file' : '$count files';
