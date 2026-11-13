/// Appearance settings: theme, editor font size, toolbar preset — all real.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/settings_controller.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/dialogs.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';
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
          icon: CfIcons.arrowBack,
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
                    icon: Icon(CfIcons.darkMode, size: 16),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(CfIcons.lightMode, size: 16),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(CfIcons.brightnessAuto, size: 16),
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
            CfSettingsTile(
              key: const ValueKey('toolbar_keys_tile'),
              leading: const Icon(CfIcons.keyboard),
              title: 'Your keys',
              subtitle: settings.toolbarKeys.isEmpty
                  ? "Presets follow each file's language"
                  : settings.toolbarKeys,
              onTap: () => _editToolbarKeys(
                context,
                settings.toolbarKeys,
                notifier.setToolbarKeys,
              ),
            ),
            const SizedBox(height: CfSpacing.xl),
          ],
        ),
      ),
    );
  }
}

/// Asks for the user's own toolbar keys and keeps them.
Future<void> _editToolbarKeys(
  BuildContext context,
  String current,
  Future<void> Function(String keys) save,
) async {
  final keys = await showDialog<String>(
    context: context,
    builder: (context) => _ToolbarKeysDialog(initial: current),
  );
  if (keys != null) {
    await save(keys);
  }
}

class _ToolbarKeysDialog extends StatefulWidget {
  const _ToolbarKeysDialog({required this.initial});

  final String initial;

  @override
  State<_ToolbarKeysDialog> createState() => _ToolbarKeysDialogState();
}

class _ToolbarKeysDialogState extends State<_ToolbarKeysDialog> {
  late final TextEditingController _keys;

  @override
  void initState() {
    super.initState();
    _keys = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CfAlertDialog(
      key: const ValueKey('toolbar_keys_dialog'),
      title: const Text('Your toolbar keys'),
      content: TextField(
        key: const ValueKey('toolbar_keys_field'),
        controller: _keys,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        maxLength: maxToolbarKeysLength,
        decoration: const InputDecoration(
          hintText: r'{} () ; => $',
          helperText:
              'Separate keys with spaces. Leave it empty for the '
              'presets.',
          helperMaxLines: 3,
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          key: const ValueKey('toolbar_keys_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('toolbar_keys_save'),
          onPressed: () => Navigator.of(context).pop(_keys.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
