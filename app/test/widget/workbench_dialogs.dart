/// The workbench's dialogs, opened the way its actions open them, for the
/// overflow and accessibility sweeps (Phase 2 gate G8).
library;

import 'package:codeforge/application/file_operations.dart';
import 'package:codeforge/features/workbench/editor_dialogs.dart';
import 'package:codeforge/features/workbench/explorer_dialogs.dart';
import 'package:codeforge/features/workbench/file_dialogs.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:flutter/widgets.dart';

/// A dialog: how to open it, the key of its confirming action, and the key
/// of its text field when it has one.
final class WorkbenchDialog {
  const WorkbenchDialog(
    this.name,
    this.open, {
    required this.confirm,
    this.field,
  });

  final String name;
  final Future<Object?> Function(BuildContext context) open;
  final String confirm;
  final String? field;
}

final List<WorkbenchDialog> workbenchDialogs = [
  WorkbenchDialog(
    'go to line',
    (context) => askLineTarget(context, lineCount: 120, currentLine: 7),
    confirm: 'goto_line_confirm',
    field: 'goto_line_field',
  ),
  WorkbenchDialog(
    'save as',
    (context) => askFilePath(
      context,
      title: 'Save as',
      confirmLabel: 'Save',
      initialPath: 'src/main.js',
    ),
    confirm: 'file_path_confirm',
    field: 'file_path_field',
  ),
  WorkbenchDialog(
    'unsaved changes',
    (context) => askUnsavedChanges(context, 'main.js'),
    confirm: 'unsaved_save',
  ),
  WorkbenchDialog(
    'restored changes conflict',
    (context) => askRestoredConflict(context, 'main.js', fileGone: false),
    confirm: 'conflict_keep',
  ),
  WorkbenchDialog(
    'confirm overwrite',
    (context) => askToConfirm(
      context,
      title: 'Overwrite main.js?',
      message:
          'The file changed on disk after it was opened. Saving replaces '
          'those changes with yours.',
      confirmLabel: 'Overwrite',
    ),
    confirm: 'confirm_ok',
  ),
  // The explorer's (Phase 3 W4).
  WorkbenchDialog(
    'new folder',
    (context) => askFilePath(
      context,
      title: 'New folder',
      confirmLabel: 'Create',
      initialPath: 'src/',
      hint: 'src/components',
      folder: true,
    ),
    confirm: 'file_path_confirm',
    field: 'file_path_field',
  ),
  WorkbenchDialog(
    'rename',
    (context) => askName(
      context,
      title: 'Rename main.js',
      confirmLabel: 'Rename',
      name: 'main.js',
      isFolder: false,
      submit: (_) async => null,
    ),
    confirm: 'name_confirm',
    field: 'name_field',
  ),
  WorkbenchDialog(
    'move to',
    (context) => askMoveTarget(
      context,
      entry: const FileEntry(path: 'main.js', name: 'main.js', isDirectory: false),
      submit: (_) async => null,
    ),
    confirm: 'move_confirm',
  ),
  WorkbenchDialog(
    'delete',
    (context) => askToDelete(
      context,
      entry: const FileEntry(path: 'src', name: 'src', isDirectory: true),
      count: const FileCount(files: 12, complete: true),
      unsaved: 1,
      sharedStorage: true,
    ),
    confirm: 'delete_confirm',
  ),
];
