/// Debug-only component gallery: every Forge component in every state.
/// Also the surface golden tests render (gate G3).
library;

import 'package:flutter/material.dart';

import '../../design_system/components/buttons.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/components/file_tree.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/components/workbench_chrome.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';

class DevGalleryScreen extends StatelessWidget {
  const DevGalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Forge gallery')),
      body: const SingleChildScrollView(child: GalleryBody()),
    );
  }
}

/// The gallery content, also used directly by golden tests.
class GalleryBody extends StatelessWidget {
  const GalleryBody({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(CfSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Buttons', style: textTheme.titleMedium),
          const SizedBox(height: CfSpacing.sm),
          Wrap(
            spacing: CfSpacing.sm,
            runSpacing: CfSpacing.sm,
            children: [
              CfButton(label: 'Primary', icon: Icons.bolt, onPressed: () {}),
              CfButton(
                label: 'Tonal',
                variant: CfButtonVariant.tonal,
                onPressed: () {},
              ),
              CfButton(
                label: 'Ghost',
                variant: CfButtonVariant.ghost,
                onPressed: () {},
              ),
              const CfButton(label: 'Disabled', onPressed: null),
            ],
          ),
          const SizedBox(height: CfSpacing.lg),
          Text('Icon buttons', style: textTheme.titleMedium),
          const SizedBox(height: CfSpacing.sm),
          Row(
            children: [
              CfIconButton(
                icon: Icons.search,
                tooltip: 'Search',
                onPressed: () {},
              ),
              CfIconButton(
                icon: Icons.folder_outlined,
                tooltip: 'Selected',
                selected: true,
                onPressed: () {},
              ),
              const CfIconButton(
                icon: Icons.play_arrow,
                tooltip: 'Disabled',
                onPressed: null,
              ),
            ],
          ),
          const SizedBox(height: CfSpacing.lg),
          Text('Banners', style: textTheme.titleMedium),
          const SizedBox(height: CfSpacing.sm),
          const CfBanner(message: 'Info: the shell is real, the editor is next.'),
          const SizedBox(height: CfSpacing.sm),
          const CfBanner(
            message: 'Warning: runtime not installed.',
            kind: CfBannerKind.warning,
          ),
          const SizedBox(height: CfSpacing.sm),
          const CfBanner(
            message: 'Danger: process exited unexpectedly.',
            kind: CfBannerKind.danger,
          ),
          const SizedBox(height: CfSpacing.lg),
          Text('Status chips', style: textTheme.titleMedium),
          const SizedBox(height: CfSpacing.sm),
          Wrap(
            spacing: CfSpacing.sm,
            children: [
              const CfStatusChip(icon: Icons.fork_right, label: 'main'),
              CfStatusChip(
                icon: Icons.circle,
                label: 'ready',
                color: colors.success,
              ),
              CfStatusChip(
                icon: Icons.circle,
                label: 'unhealthy',
                color: colors.danger,
              ),
            ],
          ),
          const SizedBox(height: CfSpacing.lg),
          Text('Tab strip', style: textTheme.titleMedium),
          const SizedBox(height: CfSpacing.sm),
          CfTabStrip(
            tabs: const [
              CfTab(id: 'a', label: 'main.js', dirty: true),
              CfTab(id: 'b', label: 'app.py'),
              CfTab(id: 'c', label: 'README.md'),
            ],
            activeId: 'a',
            onActivate: (_) {},
            onClose: (_) {},
          ),
          const SizedBox(height: CfSpacing.lg),
          Text('Tree rows', style: textTheme.titleMedium),
          const SizedBox(height: CfSpacing.sm),
          CfTreeRow(
            node: const CfFileNode(
              name: 'src',
              path: 'src',
              isFile: false,
            ),
            depth: 0,
            expanded: true,
            onTap: () {},
          ),
          CfTreeRow(
            node: const CfFileNode(
              name: 'greeting.dart',
              path: 'src/greeting.dart',
              isFile: true,
            ),
            depth: 1,
            expanded: false,
            selected: true,
            onTap: () {},
          ),
          CfTreeRow(
            node: const CfFileNode(
              name: '.gitignore',
              path: '.gitignore',
              isFile: true,
              hidden: true,
            ),
            depth: 0,
            expanded: false,
            onTap: () {},
          ),
          const SizedBox(height: CfSpacing.lg),
          Text('Settings tiles', style: textTheme.titleMedium),
          const SizedBox(height: CfSpacing.sm),
          const CfSettingsTile(
            leading: Icon(Icons.palette_outlined),
            title: 'Appearance',
            subtitle: 'Theme, editor font, motion',
            trailing: Icon(Icons.chevron_right, size: 18),
          ),
          CfSettingsTile(
            leading: const Icon(Icons.motion_photos_off_outlined),
            title: 'Reduced motion',
            trailing: Switch(value: true, onChanged: (_) {}),
          ),
          const SizedBox(height: CfSpacing.lg),
          Text('Symbol toolbar (disabled)', style: textTheme.titleMedium),
          const SizedBox(height: CfSpacing.sm),
          const CfSymbolToolbar(),
          const SizedBox(height: CfSpacing.lg),
          Text('Empty state', style: textTheme.titleMedium),
          const SizedBox(height: CfSpacing.sm),
          const SizedBox(
            height: 320,
            child: CfEmptyState(
              icon: Icons.terminal,
              title: 'Terminal',
              message: 'The sealed Linux runtime powers this pane.',
              phaseNote: 'Arrives in Phases 4–5',
            ),
          ),
          const SizedBox(height: CfSpacing.xl),
        ],
      ),
    );
  }
}
