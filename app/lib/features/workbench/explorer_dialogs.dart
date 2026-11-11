/// Dialogs of the explorer's operations (Phase 3 W4,
/// features/workbench/explorer_actions.dart): where to move an item, and
/// whether to delete one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/file_operations.dart';
import '../../application/settings_controller.dart';
import '../../application/workspace_controller.dart';
import '../../core/errors/failure.dart';
import '../../core/files/workspace_path.dart';
import '../../design_system/components/dialogs.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../services/contracts.dart';

/// Asks where to move [entry]: the workspace's folders as a tree, listed as
/// they are expanded. The item itself, the folders in it and the folder it
/// is in already can't be chosen. The dialog stays open until [submit]
/// accepts the folder (returns null) or the user cancels, showing what
/// [submit] returned otherwise: a name that is taken there. Null when
/// cancelled.
Future<String?> askMoveTarget(
  BuildContext context, {
  required FileEntry entry,
  required Future<String?> Function(String folder) submit,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _MoveTargetDialog(entry: entry, submit: submit),
  );
}

class _MoveTargetDialog extends ConsumerStatefulWidget {
  const _MoveTargetDialog({required this.entry, required this.submit});

  final FileEntry entry;
  final Future<String?> Function(String folder) submit;

  @override
  ConsumerState<_MoveTargetDialog> createState() => _MoveTargetDialogState();
}

class _MoveTargetDialogState extends ConsumerState<_MoveTargetDialog> {
  final Set<String> _expanded = {''};
  String? _chosen;
  String? _problem;
  bool _busy = false;

  /// Whether [folder] can take the item: not the item or a folder in it,
  /// and not where it is already.
  bool _allowed(String folder) =>
      folder != pathParent(widget.entry.path) &&
      (folder.isEmpty || !isWithin(folder, widget.entry.path));

  void _toggle(String folder) {
    setState(() {
      if (!_expanded.remove(folder)) {
        _expanded.add(folder);
      }
    });
    final workspace = ref.read(workspaceControllerProvider);
    if (_expanded.contains(folder) && !workspace.listings.containsKey(folder)) {
      unawaited(ref.read(workspaceControllerProvider.notifier).load(folder));
    }
  }

  Future<void> _submit() async {
    final chosen = _chosen;
    if (chosen == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    final refused = await widget.submit(chosen);
    if (!mounted) {
      return;
    }
    if (refused != null) {
      setState(() {
        _busy = false;
        _problem = refused;
      });
      return;
    }
    Navigator.of(context).pop(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(workspaceControllerProvider);
    final showHidden = ref.watch(
      settingsControllerProvider.select((s) => s.showHiddenFiles),
    );
    final rows = <({String path, String name, int depth})>[
      (
        path: '',
        name: workspace.workspace?.displayName ?? 'Workspace',
        depth: 0,
      ),
    ];
    void add(String folder, int depth) {
      final listing = workspace.listings[folder];
      if (listing is! Ok<List<FileEntry>>) {
        return;
      }
      for (final item in listing.value) {
        if (!item.isDirectory ||
            (item.hidden && !showHidden) ||
            item.path == widget.entry.path) {
          continue;
        }
        rows.add((path: item.path, name: item.name, depth: depth));
        if (_expanded.contains(item.path)) {
          add(item.path, depth + 1);
        }
      }
    }

    add('', 1);
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final problem = _problem;
    return CfAlertDialog(
      key: const ValueKey('move_dialog'),
      title: Text('Move ${widget.entry.name} to…'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final row in rows)
            _FolderRow(
              key: ValueKey('move_target_${row.path}'),
              name: row.name,
              depth: row.depth,
              expanded: _expanded.contains(row.path),
              canExpand: row.path.isNotEmpty,
              selected: row.path == _chosen,
              enabled: _allowed(row.path),
              onToggle: () => _toggle(row.path),
              onSelect: () => setState(() {
                _chosen = row.path;
                _problem = null;
              }),
            ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: CfSpacing.sm),
              child: Text(
                problem,
                key: const ValueKey('move_problem'),
                style: textTheme.bodySmall?.copyWith(color: colors.danger),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('move_cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('move_confirm'),
          onPressed: _chosen == null || _busy ? null : _submit,
          child: const Text('Move here'),
        ),
      ],
    );
  }
}

/// One folder in the move dialog's tree: a 48 dp row that chooses it, with
/// a 48 dp chevron that expands it.
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    super.key,
    required this.name,
    required this.depth,
    required this.expanded,
    required this.canExpand,
    required this.selected,
    required this.enabled,
    required this.onToggle,
    required this.onSelect,
  });

  final String name;
  final int depth;
  final bool expanded;
  final bool canExpand;
  final bool selected;
  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: enabled ? colors.textPrimary : colors.textDisabled,
    );
    return Material(
      color: selected ? colors.accentEmberSoft : Colors.transparent,
      child: Semantics(
        selected: selected,
        enabled: enabled,
        child: InkWell(
          onTap: enabled ? onSelect : null,
          child: SizedBox(
            height: CfSpacing.minTouchTarget,
            child: Row(
              children: [
                SizedBox(width: depth * 16.0),
                SizedBox(
                  width: CfSpacing.minTouchTarget,
                  child: canExpand
                      ? IconButton(
                          tooltip: expanded ? 'Collapse $name' : 'Expand $name',
                          icon: Icon(
                            expanded ? Icons.expand_more : Icons.chevron_right,
                            size: 18,
                          ),
                          onPressed: onToggle,
                        )
                      : null,
                ),
                Icon(
                  expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                  size: 16,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: CfSpacing.sm),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks to delete [entry], saying what goes: the file, or the folder and
/// how many files are in it ([count], when it was counted); that open files
/// with unsaved changes keep their text ([unsaved]); and that a delete is
/// permanent, which on shared storage ([sharedStorage]) means Android keeps
/// no bin for it. Dismissing says no.
Future<bool> askToDelete(
  BuildContext context, {
  required FileEntry entry,
  required FileCount? count,
  required int unsaved,
  required bool sharedStorage,
}) async {
  final colors = CfColors.of(context);
  final message = deleteMessage(
    entry: entry,
    count: count,
    unsaved: unsaved,
    sharedStorage: sharedStorage,
  );
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => CfAlertDialog(
      key: const ValueKey('delete_dialog'),
      title: Text(
        entry.isDirectory
            ? 'Delete the folder ${entry.name}?'
            : 'Delete ${entry.name}?',
      ),
      content: Text(message),
      actions: [
        TextButton(
          key: const ValueKey('delete_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('delete_confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: colors.danger,
            foregroundColor: colors.surfaceBase,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// What the delete dialog says about [entry] (see [askToDelete]).
String deleteMessage({
  required FileEntry entry,
  required FileCount? count,
  required int unsaved,
  required bool sharedStorage,
}) {
  final parts = <String>[];
  if (!entry.isDirectory) {
    parts.add('${entry.path} is deleted.');
  } else if (count == null) {
    parts.add('${entry.path} is deleted with everything in it.');
  } else if (count.files == 0) {
    parts.add('${entry.path} is deleted. It holds no files.');
  } else {
    final files = count.files == 1 ? '1 file' : '${count.files} files';
    parts.add(
      count.complete
          ? '${entry.path} is deleted with the $files in it.'
          : '${entry.path} is deleted with the $files or more in it.',
    );
  }
  if (unsaved == 1) {
    parts.add(
      'One open file has unsaved changes. Its tab stays open with them, '
      'marked deleted, so you can save it again.',
    );
  } else if (unsaved > 1) {
    parts.add(
      '$unsaved open files have unsaved changes. Their tabs stay open with '
      'them, marked deleted, so you can save them again.',
    );
  }
  parts.add(
    sharedStorage
        ? 'This folder is on shared storage, where a delete is permanent: '
              'Android keeps no bin there.'
        : 'This can’t be undone.',
  );
  return parts.join('\n\n');
}
