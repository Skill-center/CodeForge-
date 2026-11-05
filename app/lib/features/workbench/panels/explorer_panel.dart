/// Explorer: real expand/collapse tree over the demo workspace.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/editor_tabs_controller.dart';
import '../../../application/providers.dart';
import '../../../application/settings_controller.dart';
import '../../../core/errors/failure.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/file_tree.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../services/contracts.dart';

final _expandedDirsProvider =
    NotifierProvider<_ExpandedDirsNotifier, Set<String>>(
      _ExpandedDirsNotifier.new,
    );

final class _ExpandedDirsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.keepAlive();
    return const {''};
  }

  void toggle(String path) {
    final next = Set.of(state);
    if (!next.remove(path)) {
      next.add(path);
    }
    state = next;
  }
}

class ExplorerPanel extends ConsumerStatefulWidget {
  const ExplorerPanel({super.key, this.onFileOpened});

  final VoidCallback? onFileOpened;

  @override
  ConsumerState<ExplorerPanel> createState() => _ExplorerPanelState();
}

class _ExplorerPanelState extends ConsumerState<ExplorerPanel> {
  late Future<Result<List<FileEntry>>> _rootListing;

  @override
  void initState() {
    super.initState();
    _rootListing = _load();
  }

  Future<Result<List<FileEntry>>> _load() async {
    final files = ref.read(fileServiceProvider);
    await files.openDemoWorkspace();
    return files.listDirectory('');
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final settings = ref.watch(settingsControllerProvider);
    final expanded = ref.watch(_expandedDirsProvider);
    final tabs = ref.watch(editorTabsProvider);
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
            'Demo Workspace',
            style: textTheme.labelMedium?.copyWith(color: colors.accentEmber),
          ),
        ),
        const SizedBox(height: CfSpacing.sm),
        Expanded(
          child: FutureBuilder<Result<List<FileEntry>>>(
            future: _rootListing,
            builder: (context, snapshot) {
              final result = snapshot.data;
              if (result == null) {
                return const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              return switch (result) {
                Ok<List<FileEntry>>(:final value) => ListView(
                  children: _buildRows(
                    value,
                    0,
                    expanded,
                    settings.showHiddenFiles,
                    tabs.activePath,
                  ),
                ),
                Err<List<FileEntry>>(:final failure) => Center(
                  child: Text(failure.message, style: textTheme.bodySmall),
                ),
              };
            },
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRows(
    List<FileEntry> entries,
    int depth,
    Set<String> expanded,
    bool showHidden,
    String? activePath,
  ) {
    final rows = <Widget>[];
    for (final entry in entries) {
      if (entry.hidden && !showHidden) {
        continue;
      }
      final node = CfFileNode(
        name: entry.name,
        path: entry.path,
        isFile: !entry.isDirectory,
        hidden: entry.hidden,
      );
      final isExpanded = expanded.contains(entry.path);
      rows.add(
        CfTreeRow(
          key: ValueKey('tree_${entry.path}'),
          node: node,
          depth: depth,
          expanded: isExpanded,
          selected: entry.path == activePath,
          onTap: () {
            if (entry.isDirectory) {
              ref.read(_expandedDirsProvider.notifier).toggle(entry.path);
            } else {
              ref.read(editorTabsProvider.notifier).open(entry.path);
              widget.onFileOpened?.call();
            }
          },
        ),
      );
      if (entry.isDirectory && isExpanded) {
        rows.add(_DirectoryChildren(parentPath: entry.path, depth: depth + 1));
      }
    }
    return rows;
  }
}

class _DirectoryChildren extends ConsumerStatefulWidget {
  const _DirectoryChildren({required this.parentPath, required this.depth});

  final String parentPath;
  final int depth;

  @override
  ConsumerState<_DirectoryChildren> createState() => _DirectoryChildrenState();
}

class _DirectoryChildrenState extends ConsumerState<_DirectoryChildren> {
  // Created once: a fresh Future per build would loop setState↔build forever.
  late final Future<Result<List<FileEntry>>> _listing;

  @override
  void initState() {
    super.initState();
    _listing = ref.read(fileServiceProvider).listDirectory(widget.parentPath);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final expanded = ref.watch(_expandedDirsProvider);
    final tabs = ref.watch(editorTabsProvider);
    return FutureBuilder<Result<List<FileEntry>>>(
      future: _listing,
      builder: (context, snapshot) {
        final result = snapshot.data;
        if (result is! Ok<List<FileEntry>>) {
          return const SizedBox.shrink();
        }
        final rows = <Widget>[];
        for (final entry in result.value) {
          if (entry.hidden && !settings.showHiddenFiles) {
            continue;
          }
          rows.add(
            CfTreeRow(
              key: ValueKey('tree_${entry.path}'),
              node: CfFileNode(
                name: entry.name,
                path: entry.path,
                isFile: !entry.isDirectory,
                hidden: entry.hidden,
              ),
              depth: widget.depth,
              expanded: expanded.contains(entry.path),
              selected: entry.path == tabs.activePath,
              onTap: () {
                if (entry.isDirectory) {
                  ref.read(_expandedDirsProvider.notifier).toggle(entry.path);
                } else {
                  ref.read(editorTabsProvider.notifier).open(entry.path);
                }
              },
            ),
          );
        }
        return Column(children: rows);
      },
    );
  }
}
