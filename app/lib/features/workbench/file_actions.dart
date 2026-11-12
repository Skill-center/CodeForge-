/// The workbench's file flows (docs/EDITOR_ARCHITECTURE.md, "Files"). They
/// ask before anything is lost (unsaved changes, a file changed on disk, an
/// existing file) and report failures in words. The document controller
/// does what these decide.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/documents/document_controller.dart';
import '../../application/documents/document_state.dart';
import '../../application/explorer_view_controller.dart';
import '../../application/file_index.dart';
import '../../application/file_operations.dart';
import '../../core/errors/failure.dart';
import '../../core/files/workspace_path.dart';
import '../palette/go_to_file.dart';
import 'file_dialogs.dart';

/// Shows [message] in a snack bar, replacing the one showing.
void showFileMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Saves [path]; true once it is on disk. A file that changed on disk after
/// it was opened is overwritten only after asking.
Future<bool> saveFile(BuildContext context, WidgetRef ref, String path) async {
  final documents = ref.read(documentControllerProvider.notifier);
  var result = await documents.save(path);
  if (result case Err<void>(
    failure: FileFailure(problem: FileProblem.changedOnDisk),
  )) {
    if (!context.mounted) {
      return false;
    }
    final overwrite = await askToConfirm(
      context,
      title: 'Overwrite ${pathBaseName(path)}?',
      message:
          'The file changed on disk after it was opened. Saving replaces '
          'those changes with yours.',
      confirmLabel: 'Overwrite',
    );
    if (!overwrite) {
      return false;
    }
    result = await documents.save(path, overwrite: true);
  }
  if (!context.mounted) {
    return result.isOk;
  }
  return _announce(context, result);
}

/// Asks for a new path and saves [path]'s document there, moving its tab;
/// true when saved. An existing file is replaced only after asking.
Future<bool> saveFileAs(
  BuildContext context,
  WidgetRef ref,
  String path,
) async {
  final documents = ref.read(documentControllerProvider.notifier);
  final newPath = await askFilePath(
    context,
    title: 'Save as',
    confirmLabel: 'Save',
    initialPath: path,
  );
  if (newPath == null || !context.mounted) {
    return false;
  }
  var result = await documents.saveAs(path, newPath);
  if (result case Err<void>(
    failure: FileFailure(problem: FileProblem.exists),
  )) {
    if (!context.mounted) {
      return false;
    }
    final replace = await askToConfirm(
      context,
      title: 'Replace ${pathBaseName(newPath)}?',
      message: '$newPath already exists. Saving replaces it.',
      confirmLabel: 'Replace',
    );
    if (!replace) {
      return false;
    }
    result = await documents.saveAs(path, newPath, overwrite: true);
  }
  if (!context.mounted) {
    return result.isOk;
  }
  return _announce(context, result);
}

/// Asks for a path (in [folder] to start with), creates the empty file and
/// opens it; true when it opened. Since Phase 3 W4 the dialog stays open
/// while the file cannot be created, saying why: a name that is taken asks
/// for another.
Future<bool> createNewFile(
  BuildContext context,
  WidgetRef ref, {
  String folder = '',
}) async {
  final operations = ref.read(fileOperationsProvider);
  final path = await askFilePath(
    context,
    title: 'New file',
    confirmLabel: 'Create',
    initialPath: folder.isEmpty ? '' : '$folder/',
    submit: (path) async => switch (await operations.createFile(path)) {
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

/// Closes [path]'s tab, first asking what to do with unsaved changes; true
/// when the tab closed.
Future<bool> closeFile(BuildContext context, WidgetRef ref, String path) async {
  final documents = ref.read(documentControllerProvider.notifier);
  final doc = ref.read(documentControllerProvider).documents[path];
  if (doc == null) {
    return true;
  }
  if (doc.dirty) {
    final choice = await askUnsavedChanges(context, doc.name);
    if (choice == UnsavedChoice.cancel) {
      return false;
    }
    if (choice == UnsavedChoice.save) {
      if (!context.mounted) {
        return false;
      }
      final saved = await saveFile(context, ref, path);
      if (!saved) {
        return false;
      }
    }
  }
  documents.close(path);
  return true;
}

/// Asks about each restored document whose unsaved changes no longer
/// match its file (ADR-0008), showing it while it is asked about. Each is
/// asked about once; until then both versions stay as they are.
Future<void> resolveRestoredConflicts(
  BuildContext context,
  WidgetRef ref,
) async {
  final asked = <String>{};
  while (context.mounted) {
    final state = ref.read(documentControllerProvider);
    final path = state.openPaths
        .where(
          (p) => !asked.contains(p) && state.documents[p]?.conflict != null,
        )
        .firstOrNull;
    final doc = path == null ? null : state.documents[path];
    if (path == null || doc == null) {
      return;
    }
    asked.add(path);
    final documents = ref.read(documentControllerProvider.notifier)
      ..activate(path);
    final choice = await askRestoredConflict(
      context,
      doc.name,
      fileGone: doc.conflict != DocumentConflict.changedOnDisk,
    );
    if (!context.mounted) {
      return;
    }
    switch (choice) {
      case ConflictChoice.keepChanges:
        documents.keepRestoredEdits(path);
      case ConflictChoice.useFile:
        final result = await documents.useDiskVersion(path);
        if (!context.mounted) {
          return;
        }
        _announce(context, result);
    }
  }
}

/// Closes every tab but [keep], asking about each one with unsaved changes
/// (shown while it is asked about). Cancel stops there.
Future<void> closeOtherFiles(
  BuildContext context,
  WidgetRef ref,
  String keep,
) async {
  final documents = ref.read(documentControllerProvider.notifier);
  final others = [
    for (final path in ref.read(documentControllerProvider).openPaths)
      if (path != keep) path,
  ];
  for (final path in others) {
    if (!context.mounted) {
      return;
    }
    if (ref.read(documentControllerProvider).documents[path]?.dirty ?? false) {
      documents.activate(path);
    }
    final closed = await closeFile(context, ref, path);
    if (!closed) {
      return;
    }
  }
  documents.activate(keep);
}

/// Shows why [result] failed, if it did; true when it succeeded.
bool _announce(BuildContext context, Result<void> result) {
  if (result case Err<void>(:final failure)) {
    showFileMessage(context, failure.message);
    return false;
  }
  return true;
}

/// Go to File (Phase 3 W4, Ctrl+P): picks a file by name and opens it. A
/// file that is gone since the index found it leaves the index.
Future<void> goToFile(BuildContext context, WidgetRef ref) async {
  final path = await showGoToFile(context);
  if (path == null || !context.mounted) {
    return;
  }
  final opened = await ref.read(documentControllerProvider.notifier).open(path);
  if (!context.mounted) {
    return;
  }
  if (opened case Err<void>(:final failure)) {
    if (failure case FileFailure(problem: FileProblem.notFound)) {
      ref.read(fileIndexProvider.notifier).removed(path);
    }
    showFileMessage(context, failure.message);
  }
}
