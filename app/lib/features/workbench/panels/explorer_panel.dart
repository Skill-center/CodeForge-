/// Explorer: an expand/collapse tree over the workspace's real files. The
/// listings come from the workspace controller; the expanded folders and
/// the scroll offset from the explorer's view, kept per workspace (Phase 3
/// W3), so a switch and a cold start bring both back.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/documents/document_controller.dart';
import '../../../application/explorer_view_controller.dart';
import '../../../application/settings_controller.dart';
import '../../../application/workspace_controller.dart';
import '../../../core/errors/failure.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/file_tree.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../services/contracts.dart';
import '../file_actions.dart';

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

  final ScrollController _scroll = ScrollController();

  /// Where the tree should scroll once it is long enough; null when there
  /// is nothing to restore.
  double? _restoreTarget;
  int _restoreTriesLeft = 0;
  Timer? _restoreRetry;

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

  Future<void> _newFile() async {
    final created = await createNewFile(context, ref);
    if (created && mounted) {
      widget.onFileOpened?.call();
    }
  }

  void _onEntryTap(FileEntry entry) {
    if (entry.isDirectory) {
      ref.read(explorerViewProvider.notifier).toggle(entry.path);
    } else {
      unawaited(_openFile(entry.path));
    }
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
                icon: Icons.note_add_outlined,
                tooltip: 'New file',
                size: 16,
                onPressed: workspace.workspace == null ? null : _newFile,
              ),
              CfIconButton(
                key: const ValueKey('explorer_toggle_hidden'),
                icon: settings.showHiddenFiles
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
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
        Expanded(child: _buildTree(workspace, textTheme)),
      ],
    );
  }

  /// Nothing opened, failed or listed yet.
  static bool _pristine(WorkspaceState state) =>
      state.workspace == null &&
      state.failure == null &&
      state.listings.isEmpty;

  Widget _buildTree(WorkspaceState workspace, TextTheme textTheme) {
    final failure = workspace.failure;
    if (failure != null) {
      return _Message(failure.message);
    }
    return switch (workspace.listings['']) {
      null => const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      Ok<List<FileEntry>>(:final value) => ListView(
        key: const ValueKey('explorer_tree'),
        controller: _scroll,
        children: [_EntryRows(entries: value, depth: 0, onTap: _onEntryTap)],
      ),
      Err<List<FileEntry>>(:final failure) => _Message(failure.message),
    };
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

/// The rows of one folder's [entries], each expanded folder followed by
/// its own rows.
class _EntryRows extends ConsumerWidget {
  const _EntryRows({
    required this.entries,
    required this.depth,
    required this.onTap,
  });

  final List<FileEntry> entries;
  final int depth;
  final ValueChanged<FileEntry> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showHidden = ref.watch(
      settingsControllerProvider.select((s) => s.showHiddenFiles),
    );
    final expanded = ref.watch(
      explorerViewProvider.select((view) => view.expanded),
    );
    final activePath = ref.watch(
      documentControllerProvider.select((s) => s.activePath),
    );
    final rows = <Widget>[];
    for (final entry in entries) {
      if (entry.hidden && !showHidden) {
        continue;
      }
      final isExpanded = expanded.contains(entry.path);
      rows.add(
        CfTreeRow(
          key: ValueKey('tree_${entry.path}'),
          node: CfFileNode(
            name: entry.name,
            path: entry.path,
            isFile: !entry.isDirectory,
            hidden: entry.hidden,
          ),
          depth: depth,
          expanded: isExpanded,
          selected: entry.path == activePath,
          onTap: () => onTap(entry),
        ),
      );
      if (entry.isDirectory && isExpanded) {
        rows.add(
          _FolderChildren(folder: entry.path, depth: depth + 1, onTap: onTap),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// An expanded folder's rows, listed on first expansion.
class _FolderChildren extends ConsumerStatefulWidget {
  const _FolderChildren({
    required this.folder,
    required this.depth,
    required this.onTap,
  });

  final String folder;
  final int depth;
  final ValueChanged<FileEntry> onTap;

  @override
  ConsumerState<_FolderChildren> createState() => _FolderChildrenState();
}

class _FolderChildrenState extends ConsumerState<_FolderChildren> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !ref
              .read(workspaceControllerProvider)
              .listings
              .containsKey(widget.folder)) {
        unawaited(
          ref.read(workspaceControllerProvider.notifier).load(widget.folder),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final listing = ref.watch(
      workspaceControllerProvider.select((s) => s.listings[widget.folder]),
    );
    if (listing is! Ok<List<FileEntry>>) {
      return const SizedBox.shrink();
    }
    return _EntryRows(
      entries: listing.value,
      depth: widget.depth,
      onTap: widget.onTap,
    );
  }
}
