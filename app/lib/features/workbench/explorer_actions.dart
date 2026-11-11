/// The explorer's operations as the user meets them (Phase 3 W4): each
/// row's menu, and the flow behind each item. A flow asks what it needs (a
/// name, a folder, a confirmation), runs the operation
/// (application/file_operations.dart) and says why when it fails. A name
/// that is taken keeps its dialog open, asking for another: nothing is ever
/// replaced. The menu offers only what the workspace and the item allow
/// (FileCapabilities): a provider that cannot rename hides Rename.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/documents/document_controller.dart';
import '../../application/explorer_view_controller.dart';
import '../../application/file_operations.dart';
import '../../application/providers.dart';
import '../../application/workspace_controller.dart';
import '../../core/errors/failure.dart';
import '../../core/files/workspace_location.dart';
import '../../core/files/workspace_path.dart';
import '../../services/contracts.dart';
import 'explorer_dialogs.dart';
import 'file_actions.dart';
import 'file_dialogs.dart';

/// An item of a row's menu.
enum ExplorerAction {
  newFile('New File…'),
  newFolder('New Folder…'),
  rename('Rename…'),
  move('Move to…'),
  duplicate('Duplicate'),
  copyPath('Copy Path'),
  delete('Delete…');

  const ExplorerAction(this.label);

  final String label;
}

/// What [entry]'s menu offers. New items go into [folder] (the entry when
/// it is a folder, its folder otherwise), a duplicate into [parent] (the
/// entry's folder); the rest is what [entry] itself allows.
List<ExplorerAction> explorerActionsFor(
  FileEntry entry, {
  required FileCapabilities folder,
  required FileCapabilities parent,
}) {
  return [
    if (folder.write) ...[ExplorerAction.newFile, ExplorerAction.newFolder],
    if (entry.capabilities.rename) ExplorerAction.rename,
    if (entry.capabilities.move) ExplorerAction.move,
    if (parent.write) ExplorerAction.duplicate,
    ExplorerAction.copyPath,
    if (entry.capabilities.delete) ExplorerAction.delete,
  ];
}

/// What the folder [folder] allows: the workspace's top folder, or the
/// folder's own entry in its parent's listing (everything when it is not
/// listed).
FileCapabilities folderCapabilities(WorkspaceState workspace, String folder) {
  if (folder.isEmpty) {
    return workspace.workspace?.capabilities ?? FileCapabilities.all;
  }
  final listing = workspace.listings[pathParent(folder)];
  if (listing case Ok<List<FileEntry>>(:final value)) {
    for (final entry in value) {
      if (entry.path == folder) {
        return entry.capabilities;
      }
    }
  }
  return FileCapabilities.all;
}

/// The menu's groups: new items, then changes, then the delete.
int _groupOf(ExplorerAction action) => switch (action) {
  ExplorerAction.newFile || ExplorerAction.newFolder => 0,
  ExplorerAction.delete => 2,
  _ => 1,
};

/// Shows [entry]'s menu at [position] and runs what is chosen.
/// [onFileOpened] runs after a new file opened (the phone's sheet closes).
Future<void> showExplorerMenu(
  BuildContext context,
  WidgetRef ref, {
  required FileEntry entry,
  required RelativeRect position,
  VoidCallback? onFileOpened,
}) async {
  final workspace = ref.read(workspaceControllerProvider);
  final folder = entry.isDirectory ? entry.path : pathParent(entry.path);
  final actions = explorerActionsFor(
    entry,
    folder: folderCapabilities(workspace, folder),
    parent: folderCapabilities(workspace, pathParent(entry.path)),
  );
  final items = <PopupMenuEntry<ExplorerAction>>[];
  ExplorerAction? previous;
  for (final action in actions) {
    if (previous != null && _groupOf(previous) != _groupOf(action)) {
      items.add(const PopupMenuDivider());
    }
    previous = action;
    items.add(
      PopupMenuItem<ExplorerAction>(
        key: ValueKey('explorer_menu_${action.name}'),
        value: action,
        child: Text(action.label),
      ),
    );
  }
  final chosen = await showMenu<ExplorerAction>(
    context: context,
    position: position,
    items: items,
  );
  if (chosen == null || !context.mounted) {
    return;
  }
  await runExplorerAction(
    context,
    ref,
    chosen,
    entry,
    onFileOpened: onFileOpened,
  );
}

/// Runs [action] on [entry], asking what it needs.
Future<void> runExplorerAction(
  BuildContext context,
  WidgetRef ref,
  ExplorerAction action,
  FileEntry entry, {
  VoidCallback? onFileOpened,
}) async {
  final folder = entry.isDirectory ? entry.path : pathParent(entry.path);
  switch (action) {
    case ExplorerAction.newFile:
      if (await createNewFile(context, ref, folder: folder)) {
        onFileOpened?.call();
      }
    case ExplorerAction.newFolder:
      await createNewFolder(context, ref, folder: folder);
    case ExplorerAction.rename:
      await renameEntry(context, ref, entry);
    case ExplorerAction.move:
      await moveEntry(context, ref, entry);
    case ExplorerAction.duplicate:
      await duplicateEntry(context, ref, entry);
    case ExplorerAction.copyPath:
      await copyEntryPath(context, entry);
    case ExplorerAction.delete:
      await deleteEntry(context, ref, entry);
  }
}

/// Asks for a folder's path (in [folder] to start with) and creates it,
/// with any missing folders above it; true when created.
Future<bool> createNewFolder(
  BuildContext context,
  WidgetRef ref, {
  String folder = '',
}) async {
  final operations = ref.read(fileOperationsProvider);
  final path = await askFilePath(
    context,
    title: 'New folder',
    confirmLabel: 'Create',
    initialPath: folder.isEmpty ? '' : '$folder/',
    hint: 'src/components',
    folder: true,
    submit: (path) async => switch (await operations.createFolder(path)) {
      Ok<void>() => null,
      Err<void>(:final failure) => failure.message,
    },
  );
  if (path == null || !context.mounted) {
    return false;
  }
  ref.read(explorerViewProvider.notifier).select(path);
  return true;
}

/// Asks for [entry]'s new name and renames it; its open tabs follow. True
/// when renamed.
Future<bool> renameEntry(
  BuildContext context,
  WidgetRef ref,
  FileEntry entry,
) async {
  final operations = ref.read(fileOperationsProvider);
  String? renamed;
  await askName(
    context,
    title: 'Rename ${entry.name}',
    confirmLabel: 'Rename',
    name: entry.name,
    isFolder: entry.isDirectory,
    submit: (name) async {
      if (name == entry.name) {
        return null;
      }
      switch (await operations.rename(entry.path, name)) {
        case Ok<String>(:final value):
          renamed = value;
          return null;
        case Err<String>(failure: FileFailure(problem: FileProblem.exists)):
          return '“$name” is taken in this folder. Choose another name.';
        case Err<String>(:final failure):
          return failure.message;
      }
    },
  );
  final path = renamed;
  if (path == null || !context.mounted) {
    return false;
  }
  ref.read(explorerViewProvider.notifier).select(path);
  return true;
}

/// Asks where to move [entry] and moves it there; its open tabs follow.
/// True when moved.
Future<bool> moveEntry(
  BuildContext context,
  WidgetRef ref,
  FileEntry entry,
) async {
  final operations = ref.read(fileOperationsProvider);
  String? moved;
  await askMoveTarget(
    context,
    entry: entry,
    submit: (folder) async {
      switch (await operations.move(entry.path, folder)) {
        case Ok<String>(:final value):
          moved = value;
          return null;
        case Err<String>(failure: FileFailure(problem: FileProblem.exists)):
          return '${pathJoin(folder, entry.name)} already exists. Choose '
              'another folder, or rename one of them first.';
        case Err<String>(:final failure):
          return failure.message;
      }
    },
  );
  final path = moved;
  if (path == null || !context.mounted) {
    return false;
  }
  ref.read(explorerViewProvider.notifier)
    ..reveal(path)
    ..select(path);
  return true;
}

/// Copies [entry] beside itself under a free name (`app copy.js`).
Future<void> duplicateEntry(
  BuildContext context,
  WidgetRef ref,
  FileEntry entry,
) async {
  final result = await ref
      .read(fileOperationsProvider)
      .duplicate(entry.path, isFolder: entry.isDirectory);
  if (!context.mounted) {
    return;
  }
  switch (result) {
    case Ok<String>(:final value):
      ref.read(explorerViewProvider.notifier).select(value);
    case Err<String>(:final failure):
      showFileMessage(context, failure.message);
  }
}

/// Puts [entry]'s workspace path on the clipboard.
Future<void> copyEntryPath(BuildContext context, FileEntry entry) async {
  await Clipboard.setData(ClipboardData(text: entry.path));
  if (context.mounted) {
    showFileMessage(context, 'Copied ${entry.path}');
  }
}

/// Asks to delete [entry], saying what goes, and deletes it. Clean tabs in
/// it close; tabs with unsaved changes stay, marked deleted. True when
/// deleted.
Future<bool> deleteEntry(
  BuildContext context,
  WidgetRef ref,
  FileEntry entry,
) async {
  final operations = ref.read(fileOperationsProvider);
  FileCount? count;
  if (entry.isDirectory) {
    count = (await operations.countFiles(entry.path)).valueOrNull;
    if (!context.mounted) {
      return false;
    }
  }
  final documents = ref.read(documentControllerProvider);
  final unsaved = [
    for (final path in documents.openPaths)
      if (isWithin(path, entry.path) &&
          (documents.documents[path]?.dirty ?? false))
        path,
  ].length;
  final confirmed = await askToDelete(
    context,
    entry: entry,
    count: count,
    unsaved: unsaved,
    sharedStorage: ref.read(currentWorkspaceProvider) is FolderLocation,
  );
  if (!confirmed || !context.mounted) {
    return false;
  }
  final result = await operations.delete(entry.path);
  if (!context.mounted) {
    return result.isOk;
  }
  if (result case Err<void>(:final failure)) {
    showFileMessage(context, failure.message);
    return false;
  }
  return true;
}
