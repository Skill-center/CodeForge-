/// Editor pane: tabs and the find bar over the hosted editor page, and the
/// symbol toolbar below it. The page itself lives in [EditorSurfaceView];
/// the tabs are the open documents (Phase 2 W4), the find bar searches the
/// active one and the toolbar types into it (W6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/documents/document_controller.dart';
import '../../../application/editor/find_controller.dart';
import '../../../application/keyboard_state.dart';
import '../../../application/settings_controller.dart';
import '../../../core/files/workspace_path.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/workbench_chrome.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/icons.dart';
import '../../../services/settings/settings_model.dart';
import '../file_actions.dart';
import 'editor_surface_view.dart';
import 'find_bar.dart';
import 'symbol_toolbar.dart';

class EditorPane extends ConsumerWidget {
  const EditorPane({super.key});

  /// The most the large-file banner may take, padding included: its
  /// message and action at the gate's text scales on a narrow phone. Taller
  /// text scrolls inside it rather than pushing the editor out.
  static const double largeFileBannerExtent = 160;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final documents = ref.watch(documentControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    final find = ref.watch(findControllerProvider);
    // A hardware keyboard has the symbols, so the toolbar steps aside for
    // one, unless the soft keyboard is up as well (EDITOR_ARCHITECTURE §9).
    final hardwareKeyboard = ref.watch(hardwareKeyboardProvider);
    final softKeyboard = ref.watch(softKeyboardVisibleProvider);
    final colors = CfColors.of(context);
    final activePath = documents.activePath;
    final activeDoc = documents.active;
    final canSave = activeDoc?.dirty ?? false;

    // The pane gets whatever height the layout leaves it — tiny while the
    // soft keyboard is up on a short landscape phone — so it must never
    // overflow: pinned chrome yields before content. While the find bar is
    // open, its find row comes first (the user is typing into it), then one
    // touch row of the editor, then the tab strip, then the bar's other
    // rows. The symbol toolbar and the journal banner come only when there
    // is room left for them too; a hardware keyboard has the toolbar's keys,
    // so with one attached the toolbar steps aside. The large-file banner
    // (W7) yields to all of them, and waits while the journal's is up.
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        const tabStripExtent = CfSpacing.tabStripHeight + CfSpacing.hairline;
        const editorRow = CfSpacing.minTouchTarget;
        final findRow = FindBar.heightFor(1);
        final findOpen = find.open && activeDoc != null;
        final findFirst = findOpen && height >= findRow;
        final showTabs =
            documents.openPaths.isNotEmpty &&
            (findFirst
                ? height >= findRow + editorRow + tabStripExtent
                : height >= tabStripExtent);
        final tabsExtent = showTabs ? tabStripExtent : 0.0;
        final spare = height - tabsExtent - findRow - editorRow;
        final findRows = findFirst
            ? FindBar.rowsFor(
                width: constraints.maxWidth,
                replaceOpen: find.replaceOpen,
                maxRows: 1 + (spare > 0 ? (spare / editorRow).floor() : 0),
              )
            : 1;
        // Squeezed below its find row, the bar is clipped rather than taken
        // out: leaving the tree would take the keyboard's field with it, the
        // keyboard would close, the pane grow, and the bar come back asking
        // for the keyboard again.
        final findExtent = !findOpen
            ? 0.0
            : findFirst
            ? FindBar.heightFor(findRows)
            : height;
        final showToolbar =
            settings.toolbarPreset != ToolbarPreset.none &&
            (!hardwareKeyboard || softKeyboard) &&
            height >=
                tabsExtent + findExtent + CfSymbolToolbar.extent + editorRow;
        final journalBanner =
            documents.journalProblem != null &&
            height >= tabStripExtent + findExtent + 160;
        final largeFileRoom =
            tabsExtent +
            findExtent +
            (showToolbar ? CfSymbolToolbar.extent : 0) +
            largeFileBannerExtent +
            2 * editorRow;
        // A document whose file was deleted (Phase 3 W4) says so first: its
        // text exists nowhere else. A conflict about it is asked instead.
        final deletedNotice =
            activeDoc != null &&
            activeDoc.deletedOnDisk &&
            activeDoc.conflict == null &&
            !journalBanner &&
            height >= largeFileRoom;
        final largeFileNotice =
            (activeDoc?.largeFileNotice ?? false) &&
            !journalBanner &&
            !deletedNotice &&
            height >= largeFileRoom;
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
                      deleted:
                          documents.documents[path]?.deletedOnDisk ?? false,
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
                      icon: CfIcons.save,
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
            if (journalBanner)
              const Padding(
                padding: EdgeInsets.all(CfSpacing.sm),
                child: CfBanner(
                  key: ValueKey('journal_problem'),
                  kind: CfBannerKind.danger,
                  message:
                      'Unsaved changes are not being backed up, so a crash '
                      'would lose them. Save your files to keep them safe.',
                ),
              ),
            if (deletedNotice) _DeletedNotice(path: activeDoc.path),
            if (largeFileNotice && activeDoc != null)
              _LargeFileNotice(path: activeDoc.path),
            if (findOpen)
              ClipRect(
                // Keyed like the editor body: when a banner and the toolbar
                // go in the same layout (the keyboard rising), an unkeyed
                // bar between them would be rebuilt, and its focused field
                // would take the keyboard down with it.
                key: const ValueKey('find_bar_clip'),
                child: SizedBox(
                  height: findExtent,
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: FindBar(
                      key: const ValueKey('find_bar_host'),
                      rows: findRows,
                    ),
                  ),
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
                        icon: CfIcons.code,
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
            if (showToolbar) const EditorSymbolToolbar(),
          ],
        );
      },
    );
  }
}

/// What the large-file policy switched off for the document at [path] (W7,
/// EDITOR_ARCHITECTURE §10), at most [EditorPane.largeFileBannerExtent]
/// tall: longer text scrolls inside it.
class _LargeFileNotice extends ConsumerWidget {
  const _LargeFileNotice({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    DocumentController documents() =>
        ref.read(documentControllerProvider.notifier);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: EditorPane.largeFileBannerExtent,
      ),
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.all(CfSpacing.sm),
        child: CfBanner(
          key: const ValueKey('large_file_notice'),
          message:
              'Large file: opened as plain text, without highlighting or '
              'folding, so typing stays fast.',
          actionLabel: 'Highlight anyway',
          onAction: () => documents().highlightAnyway(path),
          onDismiss: () => documents().dismissLargeFileNotice(path),
        ),
      ),
    );
  }
}

/// The document at [path] has no file behind it any more (Phase 3 W4): it
/// was deleted while it had unsaved changes. At most
/// [EditorPane.largeFileBannerExtent] tall, like the large-file banner.
class _DeletedNotice extends ConsumerWidget {
  const _DeletedNotice({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: EditorPane.largeFileBannerExtent,
      ),
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.all(CfSpacing.sm),
        child: CfBanner(
          key: const ValueKey('deleted_notice'),
          kind: CfBannerKind.warning,
          message:
              '${pathBaseName(path)} was deleted. Your text is still here: '
              'save it to write the file again, or close the tab to discard '
              'it.',
          actionLabel: 'Save',
          onAction: () => saveFile(context, ref, path),
        ),
      ),
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
      icon: const Icon(CfIcons.moreVert, size: 20),
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
