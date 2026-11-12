/// Explorer: a tree over the workspace's real files. The listings come
/// from the workspace controller; the expanded folders, the scroll offset
/// and the selected row from the explorer's view, kept per workspace (Phase
/// 3 W3), so a switch and a cold start bring the first two back.
///
/// Since Phase 3 W4 the tree is virtualised: the rows it shows are one flat
/// list ([visibleRows]), and only those on screen are built, so a folder of
/// 10,000 entries costs no more than one of ten. Every row has a menu of
/// the explorer's operations (explorer_actions.dart): a long-press, the ⋯
/// button of the selected row, or the context-menu key or Shift+F10. With a
/// hardware keyboard the arrow keys move through the tree, Enter opens, F2
/// renames and Delete deletes.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/documents/document_controller.dart';
import '../../../application/explorer_view_controller.dart';
import '../../../application/settings_controller.dart';
import '../../../application/workspace_controller.dart';
import '../../../core/errors/failure.dart';
import '../../../core/files/workspace_path.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/file_tree.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/icons.dart';
import '../../../services/contracts.dart';
import '../explorer_actions.dart';
import '../file_actions.dart';

/// One row of the tree: an entry, and how deep it sits.
typedef ExplorerRow = ({FileEntry entry, int depth});

/// The rows the tree shows, in order: the listed folders' entries, each
/// expanded folder followed by its own rows, hidden entries only when
/// [showHidden]. Expanded folders that show but are not listed yet go into
/// [unlisted].
List<ExplorerRow> visibleRows({
  required Map<String, Result<List<FileEntry>>> listings,
  required Set<String> expanded,
  required bool showHidden,
  List<String>? unlisted,
}) {
  final rows = <ExplorerRow>[];
  void add(String folder, int depth) {
    final listing = listings[folder];
    if (listing is! Ok<List<FileEntry>>) {
      return;
    }
    for (final entry in listing.value) {
      if (entry.hidden && !showHidden) {
        continue;
      }
      rows.add((entry: entry, depth: depth));
      if (entry.isDirectory && expanded.contains(entry.path)) {
        if (listings.containsKey(entry.path)) {
          add(entry.path, depth + 1);
        } else {
          unlisted?.add(entry.path);
        }
      }
    }
  }

  add('', 0);
  return rows;
}

class ExplorerPanel extends ConsumerStatefulWidget {
  const ExplorerPanel({super.key, this.onFileOpened});

  /// Called after a file opened from here (the phone sheet closes).
  final VoidCallback? onFileOpened;

  @override
  ConsumerState<ExplorerPanel> createState() => _ExplorerPanelState();
}

class _ExplorerPanelState extends ConsumerState<ExplorerPanel> {
  /// How often a restored scroll offset is tried, 100 ms apart, before the
  /// tree scrolls as far as it goes: it waits at most 5 seconds for the
  /// folders it needs. Counted rather than timed, so it behaves the same
  /// under a test's fake clock.
  static const int _restoreTries = 50;

  /// Every row is one touch target tall.
  static const double _rowExtent = CfSpacing.minTouchTarget;

  final ScrollController _scroll = ScrollController();
  final FocusNode _treeFocus = FocusNode(debugLabel: 'explorer tree');
  final GlobalKey _treeKey = GlobalKey(debugLabel: 'explorer tree');

  /// Where the tree should scroll once it is long enough; null when there
  /// is nothing to restore.
  double? _restoreTarget;
  int _restoreTriesLeft = 0;
  Timer? _restoreRetry;

  /// The rows of the last build: the keys and the menus act on them.
  List<ExplorerRow> _rows = const [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    final view = ref.read(explorerViewProvider);
    if (view.loaded) {
      _restoreTo(ref.read(explorerViewProvider.notifier).offset);
    }
    // Idempotent: the workbench has usually opened it already.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(workspaceControllerProvider.notifier).open());
      }
    });
  }

  @override
  void dispose() {
    _restoreRetry?.cancel();
    _treeFocus.dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    // Jumps toward a restored offset are not the user's scrolling.
    if (_restoreTarget == null) {
      ref.read(explorerViewProvider.notifier).setScroll(_scroll.offset);
    }
  }

  void _restoreTo(double offset) {
    _restoreRetry?.cancel();
    if (offset <= 0) {
      _restoreTarget = null;
      return;
    }
    _restoreTarget = offset;
    _restoreTriesLeft = _restoreTries;
    _afterFrame();
  }

  /// Tries the restore after the next frame: only then does the tree's
  /// length include every listing that has arrived. A listing that arrives
  /// between frames is in the workspace's state before its rows are laid
  /// out, so a check between frames could stop short.
  void _afterFrame() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _tryRestore())
      ..scheduleFrame();
  }

  /// Scrolls to the restored offset once the tree is long enough for it,
  /// or as far as it goes once every expanded folder is listed (or after
  /// [_restoreTries]).
  void _tryRestore() {
    final target = _restoreTarget;
    if (!mounted || target == null) {
      return;
    }
    _restoreTriesLeft -= 1;
    final out = _restoreTriesLeft <= 0;
    if (_scroll.hasClients) {
      final position = _scroll.position;
      if (position.maxScrollExtent >= target || _expandedListed() || out) {
        _scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent).toDouble());
        _restoreTarget = null;
        return;
      }
    } else if (out) {
      _restoreTarget = null;
      return;
    }
    _restoreRetry = Timer(const Duration(milliseconds: 100), () {
      if (mounted) {
        _afterFrame();
      }
    });
  }

  /// Every expanded folder the tree shows is listed.
  bool _expandedListed() {
    final expanded = ref.read(explorerViewProvider).expanded;
    final listings = ref.read(workspaceControllerProvider).listings;
    bool shown(String path) {
      final slash = path.lastIndexOf('/');
      if (slash < 0) {
        return true;
      }
      final parent = path.substring(0, slash);
      return expanded.contains(parent) && shown(parent);
    }

    return expanded.every((path) => !shown(path) || listings.containsKey(path));
  }

  Future<void> _openFile(String path) async {
    final result = await ref
        .read(documentControllerProvider.notifier)
        .open(path);
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<void>():
        widget.onFileOpened?.call();
      case Err<void>(:final failure):
        showFileMessage(context, failure.message);
    }
  }

  /// The folder new items go into: the selected folder, or the selected
  /// file's folder, or the top.
  String _targetFolder() {
    final selected = ref.read(explorerViewProvider).selected;
    if (selected == null) {
      return '';
    }
    for (final row in _rows) {
      if (row.entry.path == selected) {
        return row.entry.isDirectory ? selected : pathParent(selected);
      }
    }
    return '';
  }

  Future<void> _newFile() async {
    final created = await createNewFile(context, ref, folder: _targetFolder());
    if (created && mounted) {
      widget.onFileOpened?.call();
    }
  }

  void _onEntryTap(FileEntry entry) {
    final view = ref.read(explorerViewProvider.notifier)..select(entry.path);
    if (entry.isDirectory) {
      view.toggle(entry.path);
    } else {
      unawaited(_openFile(entry.path));
    }
  }

  /// Opens the menu of the row at [index], which shows [entry].
  Future<void> _openMenu(FileEntry entry, int index) async {
    ref.read(explorerViewProvider.notifier).select(entry.path);
    _reveal(index);
    final position = _menuPosition(index);
    if (position == null) {
      return;
    }
    await showExplorerMenu(
      context,
      ref,
      entry: entry,
      position: position,
      onFileOpened: widget.onFileOpened,
    );
  }

  /// Where the menu of the row at [index] opens: under its name.
  RelativeRect? _menuPosition(int index) {
    final tree = _treeKey.currentContext?.findRenderObject();
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (tree is! RenderBox || overlay is! RenderBox) {
      return null;
    }
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final depth = index < _rows.length ? _rows[index].depth : 0;
    final anchor = tree.localToGlobal(
      Offset(
        CfSpacing.sm + depth * 16.0 + 36,
        (index + 1) * _rowExtent - offset,
      ),
      ancestor: overlay,
    );
    return RelativeRect.fromRect(
      Rect.fromLTWH(anchor.dx, anchor.dy, 0, 0),
      Offset.zero & overlay.size,
    );
  }

  /// Scrolls the row at [index] into view.
  void _reveal(int index) {
    if (!_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final top = index * _rowExtent;
    final bottom = top + _rowExtent;
    if (top < position.pixels) {
      _scroll.jumpTo(top);
    } else if (bottom > position.pixels + position.viewportDimension) {
      _scroll.jumpTo(
        math.min(bottom - position.viewportDimension, position.maxScrollExtent),
      );
    }
  }

  void _selectRow(int index) {
    if (index < 0 || index >= _rows.length) {
      return;
    }
    ref.read(explorerViewProvider.notifier).select(_rows[index].entry.path);
    _reveal(index);
  }

  /// The tree's keys (a hardware keyboard): the arrow keys move through it,
  /// Home and End go to its ends, Enter or Space opens a file or toggles a
  /// folder, the context-menu key or Shift+F10 opens the menu, F2 renames
  /// and Delete deletes.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final rows = _rows;
    if (rows.isEmpty) {
      return KeyEventResult.ignored;
    }
    final view = ref.read(explorerViewProvider);
    final current = rows.indexWhere((row) => row.entry.path == view.selected);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _selectRow(current < 0 ? 0 : math.min(current + 1, rows.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _selectRow(current <= 0 ? 0 : current - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _selectRow(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _selectRow(rows.length - 1);
      return KeyEventResult.handled;
    }
    if (current < 0) {
      return KeyEventResult.ignored;
    }
    final (:entry, :depth) = rows[current];
    final isExpanded = view.expanded.contains(entry.path);
    if (key == LogicalKeyboardKey.arrowRight) {
      if (entry.isDirectory && !isExpanded) {
        ref.read(explorerViewProvider.notifier).toggle(entry.path);
      } else if (entry.isDirectory &&
          current + 1 < rows.length &&
          rows[current + 1].depth > depth) {
        _selectRow(current + 1);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (entry.isDirectory && isExpanded) {
        ref.read(explorerViewProvider.notifier).toggle(entry.path);
      } else {
        final parent = pathParent(entry.path);
        _selectRow(rows.indexWhere((row) => row.entry.path == parent));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _onEntryTap(entry);
      return KeyEventResult.handled;
    }
    final menuKey =
        key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed);
    if (menuKey) {
      unawaited(_openMenu(entry, current));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2 && entry.capabilities.rename) {
      unawaited(renameEntry(context, ref, entry));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete && entry.capabilities.delete) {
      unawaited(deleteEntry(context, ref, entry));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final settings = ref.watch(settingsControllerProvider);
    final workspace = ref.watch(workspaceControllerProvider);
    // Another workspace's files replaced the open one's while the explorer
    // shows (the workspace controller starts over): open and list it, as
    // when the explorer first appears.
    ref.listen(workspaceControllerProvider, (previous, next) {
      if (previous != null && !_pristine(previous) && _pristine(next)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(ref.read(workspaceControllerProvider.notifier).open());
          }
        });
      }
    });
    // The workspace's stored view arrived (a cold start, a switch): scroll
    // to where it was.
    ref.listen(explorerViewProvider, (previous, next) {
      if (next.loaded &&
          (previous == null ||
              !previous.loaded ||
              previous.workspaceId != next.workspaceId)) {
        _restoreTo(next.restoreOffset);
      }
    });
    // A selected file follows the active document, as the highlight did
    // before rows could be selected; a selected folder stays, since new
    // items go into it.
    ref.listen(documentControllerProvider.select((s) => s.activePath), (
      previous,
      next,
    ) {
      final selected = ref.read(explorerViewProvider).selected;
      if (next == null || selected == null || selected == next) {
        return;
      }
      final folder = _rows.any(
        (row) => row.entry.path == selected && row.entry.isDirectory,
      );
      if (!folder) {
        ref.read(explorerViewProvider.notifier).select(next);
      }
    });
    final canCreate =
        workspace.workspace != null &&
        folderCapabilities(workspace, _targetFolder()).write;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CfSpacing.lg,
            CfSpacing.md,
            CfSpacing.sm,
            CfSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'EXPLORER',
                  style: textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              CfIconButton(
                key: const ValueKey('explorer_new_file'),
                icon: CfIcons.noteAdd,
                tooltip: 'New file',
                size: 16,
                onPressed: canCreate ? _newFile : null,
              ),
              CfIconButton(
                key: const ValueKey('explorer_toggle_hidden'),
                icon: settings.showHiddenFiles
                    ? CfIcons.visibility
                    : CfIcons.visibilityOff,
                tooltip: settings.showHiddenFiles
                    ? 'Hide dotfiles'
                    : 'Show dotfiles',
                size: 16,
                onPressed: () => ref
                    .read(settingsControllerProvider.notifier)
                    .setShowHiddenFiles(!settings.showHiddenFiles),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
          child: Text(
            workspace.workspace?.displayName ?? 'Workspace',
            style: textTheme.labelMedium?.copyWith(color: colors.accentEmber),
          ),
        ),
        const SizedBox(height: CfSpacing.sm),
        Expanded(child: _buildTree(workspace, settings.showHiddenFiles)),
      ],
    );
  }

  /// Nothing opened, failed or listed yet.
  static bool _pristine(WorkspaceState state) =>
      state.workspace == null &&
      state.failure == null &&
      state.listings.isEmpty;

  Widget _buildTree(WorkspaceState workspace, bool showHidden) {
    final openFailure = workspace.failure;
    if (openFailure != null) {
      return _Message(openFailure.message);
    }
    switch (workspace.listings['']) {
      case null:
        return const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case Err<List<FileEntry>>(:final failure):
        return _Message(failure.message);
      case Ok<List<FileEntry>>():
        break;
    }
    final view = ref.watch(explorerViewProvider);
    final activePath = ref.watch(
      documentControllerProvider.select((s) => s.activePath),
    );
    final unlisted = <String>[];
    final rows = visibleRows(
      listings: workspace.listings,
      expanded: view.expanded,
      showHidden: showHidden,
      unlisted: unlisted,
    );
    _rows = rows;
    if (unlisted.isNotEmpty) {
      // Expanded folders list when they first show.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final controller = ref.read(workspaceControllerProvider.notifier);
        final listed = ref.read(workspaceControllerProvider).listings;
        for (final folder in unlisted) {
          if (!listed.containsKey(folder)) {
            unawaited(controller.load(folder));
          }
        }
      });
    }
    final highlighted = view.selected ?? activePath;
    return Focus(
      focusNode: _treeFocus,
      onKeyEvent: _onKey,
      child: KeyedSubtree(
        key: _treeKey,
        child: ListView.builder(
          key: const ValueKey('explorer_tree'),
          controller: _scroll,
          itemExtent: _rowExtent,
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final (:entry, :depth) = rows[index];
            final selected = entry.path == view.selected;
            return CfTreeRow(
              key: ValueKey('tree_${entry.path}'),
              node: CfFileNode(
                name: entry.name,
                path: entry.path,
                isFile: !entry.isDirectory,
                hidden: entry.hidden,
              ),
              depth: depth,
              expanded: view.expanded.contains(entry.path),
              selected: entry.path == highlighted,
              onTap: () {
                _treeFocus.requestFocus();
                _onEntryTap(entry);
              },
              onLongPress: () => unawaited(_openMenu(entry, index)),
              trailing: selected
                  ? CfIconButton(
                      key: ValueKey('tree_menu_${entry.path}'),
                      icon: CfIcons.moreHoriz,
                      tooltip: 'Actions for ${entry.name}',
                      size: 16,
                      onPressed: () => unawaited(_openMenu(entry, index)),
                    )
                  : null,
            );
          },
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CfSpacing.lg),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
