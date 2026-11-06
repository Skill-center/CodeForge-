/// The workbench's file flows (docs/EDITOR_ARCHITECTURE.md, "Files"). They
/// ask before anything is lost (unsaved changes, a file changed on disk, an
/// existing file) and report failures in words. The document controller
/// does what these decide.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/documents/document_controller.dart';
import '../../core/errors/failure.dart';
import '../../core/files/workspace_path.dart';
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
  if (result case Err<void>(failure: FileFailure(problem: FileProblem.exists))) {
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
/// opens it; true when it opened.
Future<bool> createNewFile(
  BuildContext context,
  WidgetRef ref, {
  String folder = '',
}) async {
  final documents = ref.read(documentControllerProvider.notifier);
  final path = await askFilePath(
    context,
    title: 'New file',
    confirmLabel: 'Create',
    initialPath: folder.isEmpty ? '' : '$folder/',
  );
  if (path == null || !context.mounted) {
    return false;
  }
  final result = await documents.createFile(path);
  if (!context.mounted) {
    return result.isOk;
  }
  return _announce(context, result);
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
