/// Settings → Editor (Phase 6 W5, PHASE_6_PLAN W5): each language's server
/// turned on or off. A server runs in the Linux runtime and gives the
/// editor completion, problems, definitions, rename and hover for its
/// languages; off, the editor still completes the document's own words.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/lsp/lsp_controller.dart';
import '../../application/settings_controller.dart';
import '../../core/lsp/lsp_models.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';

class EditorSettingsScreen extends ConsumerWidget {
  const EditorSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final notifier = ref.read(settingsControllerProvider.notifier);
    // Listened here, so a server turned off stops now: Riverpod pauses a
    // provider nobody listens to, and the editor is not on screen.
    final servers = ref.watch(lspControllerProvider);
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    bool isOn(LspServerId server) => switch (server) {
      LspServerId.pyright => settings.pythonServer,
      LspServerId.typescript => settings.typescriptServer,
    };
    return Scaffold(
      appBar: AppBar(
        leading: CfIconButton(
          icon: CfIcons.arrowBack,
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('Editor'),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            const CfSectionHeader('Language servers'),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CfSpacing.lg,
                0,
                CfSpacing.lg,
                CfSpacing.sm,
              ),
              child: Text(
                'A language server gives the editor completion, problems, '
                'go to definition, rename and hover. It runs in the Linux '
                'runtime while a file of its languages is open, and stops '
                'after 10 minutes unused.',
                style: textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            for (final server in LspServerId.values)
              CfSettingsTile(
                key: ValueKey('settings_server_${server.id}'),
                leading: const Icon(CfIcons.code),
                title: server.language,
                subtitle: servers.statuses[server]?.running ?? false
                    ? '${server.versions} · running'
                    : server.versions,
                trailing: Switch(
                  value: isOn(server),
                  onChanged: (value) =>
                      notifier.setLanguageServer(server, value),
                ),
                onTap: () => notifier.setLanguageServer(server, !isOn(server)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CfSpacing.lg,
                CfSpacing.sm,
                CfSpacing.lg,
                CfSpacing.xl,
              ),
              child: Text(
                'Off, the editor still completes the words of the file. '
                'Settings → Linux runtime shows each server running, its '
                'memory, and Restart.',
                style: textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
