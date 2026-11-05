/// Appearance settings: theme, editor font size, toolbar preset — all real.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/settings_controller.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/typography.dart';
import '../../services/settings/settings_model.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final notifier = ref.read(settingsControllerProvider.notifier);
    final colors = CfColors.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: CfIconButton(
          icon: Icons.arrow_back,
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('Appearance'),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            const CfSectionHeader('Theme'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
              child: SegmentedButton<ThemeMode>(
                key: const ValueKey('theme_selector'),
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto_outlined, size: 16),
                  ),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (selection) =>
                    notifier.setThemeMode(selection.first),
              ),
            ),
            const CfSectionHeader('Editor font size'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      key: const ValueKey('font_size_slider'),
                      value: settings.editorFontSize,
                      min: 10,
                      max: 24,
                      divisions: 14,
                      label: '${settings.editorFontSize.round()} pt',
                      onChanged: notifier.setEditorFontSize,
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${settings.editorFontSize.round()} pt',
                      style: Theme.of(context).textTheme.labelMedium,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(CfSpacing.md),
                decoration: BoxDecoration(
                  color: colors.surfaceSunken,
                  borderRadius: BorderRadius.circular(CfRadius.sm),
                  border: Border.all(color: colors.borderSubtle),
                ),
                child: Text(
                  'const forge = "hot"; // preview',
                  style: CfTypography.code(
                    colors,
                    fontSize: settings.editorFontSize,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const CfSectionHeader('Symbol toolbar'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
              child: SegmentedButton<ToolbarPreset>(
                key: const ValueKey('toolbar_selector'),
                segments: const [
                  ButtonSegment(
                    value: ToolbarPreset.standard,
                    label: Text('Standard'),
                  ),
                  ButtonSegment(
                    value: ToolbarPreset.compact,
                    label: Text('Compact'),
                  ),
                  ButtonSegment(value: ToolbarPreset.none, label: Text('Off')),
                ],
                selected: {settings.toolbarPreset},
                onSelectionChanged: (selection) =>
                    notifier.setToolbarPreset(selection.first),
              ),
            ),
            const SizedBox(height: CfSpacing.xl),
          ],
        ),
      ),
    );
  }
}
