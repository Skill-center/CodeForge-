/// Editor pane: tabs over the hosted editor page (Phase 2 W2) and the symbol
/// toolbar below it. The page itself lives in [EditorSurfaceView].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/editor_tabs_controller.dart';
import '../../../application/settings_controller.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/workbench_chrome.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../services/settings/settings_model.dart';
import 'editor_surface_view.dart';

class EditorPane extends ConsumerWidget {
  const EditorPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(editorTabsProvider);
    final settings = ref.watch(settingsControllerProvider);
    final colors = CfColors.of(context);
    final activeDoc = tabs.activePath == null
        ? null
        : tabs.documents[tabs.activePath];
    final canSave = activeDoc?.dirty ?? false;

    // The pane gets whatever height the layout leaves it — tiny while the
    // soft keyboard is up on a short landscape phone — so it must never
    // overflow: pinned chrome yields before content. The tab strip needs its
    // own height, and the (disabled) symbol toolbar stays only while a touch
    // row of the editor still fits beside it.
    return LayoutBuilder(
      builder: (context, constraints) {
        const tabStripExtent = CfSpacing.tabStripHeight + CfSpacing.hairline;
        final showTabs =
            tabs.openPaths.isNotEmpty &&
            constraints.maxHeight >= tabStripExtent;
        final showToolbar =
            settings.toolbarPreset != ToolbarPreset.none &&
            constraints.maxHeight >=
                (showTabs ? tabStripExtent : 0) +
                    CfSpacing.symbolToolbarHeight +
                    CfSpacing.minTouchTarget;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showTabs)
              CfTabStrip(
                tabs: [
                  for (final path in tabs.openPaths)
                    CfTab(
                      id: path,
                      label: path.split('/').last,
                      dirty: tabs.documents[path]?.dirty ?? false,
                    ),
                ],
                activeId: tabs.activePath,
                onActivate: (id) =>
                    ref.read(editorTabsProvider.notifier).activate(id),
                onClose: (id) =>
                    ref.read(editorTabsProvider.notifier).close(id),
                trailing: CfIconButton(
                  key: const ValueKey('editor_save'),
                  icon: Icons.save_outlined,
                  tooltip: 'Save file',
                  onPressed: canSave
                      ? () => ref.read(editorTabsProvider.notifier).saveActive()
                      : null,
                ),
              ),
            Expanded(
              // Keyed: when the tab strip and the toolbar come or go in the
              // same layout (the keyboard opening on a short landscape
              // phone), an unkeyed child here would be torn down and rebuilt
              // — and the WebView with it.
              key: const ValueKey('editor_body'),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Always mounted: the page loads, and keeps its documents,
                  // even while no tab is open.
                  const EditorSurfaceView(),
                  if (activeDoc == null)
                    ColoredBox(
                      color: colors.surfaceBase,
                      child: CfEmptyState(
                        icon: Icons.code,
                        title: 'No file open',
                        message: 'Pick a file from the explorer to edit it.',
                        actionLabel: 'Open main.js',
                        onAction: () => ref
                            .read(editorTabsProvider.notifier)
                            .open('main.js'),
                      ),
                    ),
                ],
              ),
            ),
            if (showToolbar)
              const CfSymbolToolbar(
                enabled: false,
                phaseNote: 'Symbol keys arrive later in Phase 2',
              ),
          ],
        );
      },
    );
  }
}
