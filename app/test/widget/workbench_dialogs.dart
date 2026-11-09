/// The workbench's dialogs, opened the way its actions open them, for the
/// overflow and accessibility sweeps (Phase 2 gate G8).
library;

import 'package:codeforge/features/workbench/editor_dialogs.dart';
import 'package:codeforge/features/workbench/file_dialogs.dart';
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
];
