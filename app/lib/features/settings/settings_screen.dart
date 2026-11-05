/// Settings root page. Every toggle here is real and persisted (G5).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/settings_controller.dart';
import '../../application/shell_controller.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/geometry.dart';

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

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    return Scaffold(
      appBar: AppBar(
        leading: CfIconButton(
          icon: Icons.arrow_back,
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
              leading: const Icon(Icons.palette_outlined),
              title: 'Appearance',
              subtitle: 'Theme, editor font, motion, toolbar',
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => context.go('/settings/appearance'),
            ),
            CfSettingsTile(
              key: const ValueKey('settings_reduced_motion'),
              leading: const Icon(Icons.motion_photos_off_outlined),
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
            const CfSectionHeader('Coming in later phases'),
            const CfSettingsTile(
              leading: Icon(Icons.folder_outlined),
              title: 'Storage & folders',
              subtitle: 'Phase 3 — SAF workspace access',
              onTap: null,
            ),
            const CfSettingsTile(
              leading: Icon(Icons.memory),
              title: 'Linux runtime',
              subtitle: 'Phase 4 — install and health',
              onTap: null,
            ),
            const CfSettingsTile(
              leading: Icon(Icons.extension_outlined),
              title: 'Extensions',
              subtitle: 'Phase 7 — curated catalog',
              onTap: null,
            ),
            const CfSectionHeader('About'),
            CfSettingsTile(
              leading: const Icon(Icons.info_outline),
              title: 'About CodeForge',
              subtitle: 'Version, licenses, diagnostics',
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => context.go('/settings/about'),
            ),
            if (kDebugMode)
              CfSettingsTile(
                key: const ValueKey('settings_gallery'),
                leading: const Icon(Icons.design_services_outlined),
                title: 'Component gallery',
                subtitle: 'Debug only — Forge design system',
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => context.go('/settings/gallery'),
              ),
            const SizedBox(height: CfSpacing.xl),
          ],
        ),
      ),
    );
  }
}
