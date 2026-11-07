/// Editor pane: tabs over the hosted editor page and the symbol toolbar
/// below it. The page itself lives in [EditorSurfaceView]; the tabs are the
/// open documents (Phase 2 W4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/documents/document_controller.dart';
import '../../../application/settings_controller.dart';
import '../../../core/files/workspace_path.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/workbench_chrome.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../services/settings/settings_model.dart';
import '../file_actions.dart';
import 'editor_surface_view.dart';

class EditorPane extends ConsumerWidget {
  const EditorPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final documents = ref.watch(documentControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    final colors = CfColors.of(context);
    final activePath = documents.activePath;
    final activeDoc = documents.active;
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
            documents.openPaths.isNotEmpty &&
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
                  for (final path in documents.openPaths)
                    CfTab(
                      id: path,
                      label: pathBaseName(path),
                      dirty: documents.documents[path]?.dirty ?? false,
                    ),
                ],
                activeId: activePath,
                onActivate: (id) =>
                    ref.read(documentControllerProvider.notifier).activate(id),
                // Asks first when the tab has unsaved changes.
                onClose: (id) => closeFile(context, ref, id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CfIconButton(
                      key: const ValueKey('editor_save'),
                      icon: Icons.save_outlined,
                      tooltip: 'Save file',
                      onPressed: activePath != null && canSave
                          ? () => saveFile(context, ref, activePath)
                          : null,
                    ),
                    _FileMenu(
                      activePath: activePath,
                      canCloseOthers: documents.openPaths.length > 1,
                    ),
                  ],
                ),
              ),
            if (documents.journalProblem != null &&
                constraints.maxHeight >= tabStripExtent + 160)
              Padding(
                padding: const EdgeInsets.all(CfSpacing.sm),
                child: CfBanner(
                  key: const ValueKey('journal_problem'),
                  kind: CfBannerKind.danger,
                  message:
                      'Unsaved changes are not being backed up, so a crash '
                      'would lose them. Save your files to keep them safe.',
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
                        message:
                            'Pick a file from the explorer, or create a new '
                            'one.',
                        actionLabel: 'New file',
                        onAction: () => createNewFile(context, ref),
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

enum _FileAction { newFile, saveAs, closeOthers }

/// The tab strip's overflow menu: file actions that need no screen space
/// of their own.
class _FileMenu extends ConsumerWidget {
  const _FileMenu({required this.activePath, required this.canCloseOthers});

  final String? activePath;
  final bool canCloseOthers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePath = this.activePath;
    return PopupMenuButton<_FileAction>(
      key: const ValueKey('editor_menu'),
      tooltip: 'File actions',
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (action) {
        switch (action) {
          case _FileAction.newFile:
            createNewFile(context, ref);
          case _FileAction.saveAs:
            if (activePath != null) {
              saveFileAs(context, ref, activePath);
            }
          case _FileAction.closeOthers:
            if (activePath != null) {
              closeOtherFiles(context, ref, activePath);
            }
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          key: ValueKey('menu_new_file'),
          value: _FileAction.newFile,
          child: Text('New file…'),
        ),
        PopupMenuItem(
          key: const ValueKey('menu_save_as'),
          value: _FileAction.saveAs,
          enabled: activePath != null,
          child: const Text('Save as…'),
        ),
        PopupMenuItem(
          key: const ValueKey('menu_close_others'),
          value: _FileAction.closeOthers,
          enabled: canCloseOthers,
          child: const Text('Close other tabs'),
        ),
      ],
    );
  }
}
