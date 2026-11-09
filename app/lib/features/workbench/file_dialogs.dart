/// Dialogs of the workbench's file flows (features/workbench/file_actions.dart).
library;

import 'package:flutter/material.dart';

import '../../core/files/workspace_path.dart';
import '../../design_system/components/dialogs.dart';

/// What to do with unsaved changes.
enum UnsavedChoice { save, discard, cancel }

/// Asks what to do with the unsaved changes of [name]. Dismissing the
/// dialog cancels.
Future<UnsavedChoice> askUnsavedChanges(
  BuildContext context,
  String name,
) async {
  final choice = await showDialog<UnsavedChoice>(
    context: context,
    builder: (context) => CfAlertDialog(
      key: const ValueKey('unsaved_dialog'),
      title: Text('Save changes to $name?'),
      content: const Text('Your changes are lost if you don’t save them.'),
      actions: [
        TextButton(
          key: const ValueKey('unsaved_cancel'),
          onPressed: () => Navigator.of(context).pop(UnsavedChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('unsaved_discard'),
          onPressed: () => Navigator.of(context).pop(UnsavedChoice.discard),
          child: const Text('Don’t Save'),
        ),
        FilledButton(
          key: const ValueKey('unsaved_save'),
          onPressed: () => Navigator.of(context).pop(UnsavedChoice.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return choice ?? UnsavedChoice.cancel;
}

/// What to keep when restored unsaved changes no longer match their file.
enum ConflictChoice { keepChanges, useFile }

/// Asks what to keep of [name]: the unsaved changes restored after the app
/// closed, or the file as it is now. [fileGone] says the file was deleted
/// or can no longer be read, so "the file" means dropping the changes.
/// Dismissing keeps the changes: nothing is lost by default.
Future<ConflictChoice> askRestoredConflict(
  BuildContext context,
  String name, {
  required bool fileGone,
}) async {
  final choice = await showDialog<ConflictChoice>(
    context: context,
    barrierDismissible: false,
    builder: (context) => CfAlertDialog(
      key: const ValueKey('conflict_dialog'),
      title: Text(
        fileGone ? '$name is no longer available' : '$name changed on disk',
      ),
      content: Text(
        fileGone
            ? 'CodeForge closed while $name had unsaved changes, and the file '
                  'can no longer be opened. Keep your changes to save it '
                  'again, or discard them.'
            : 'CodeForge closed while $name had unsaved changes, and the '
                  'file has changed since. Both versions are kept until you '
                  'choose.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('conflict_use_file'),
          onPressed: () => Navigator.of(context).pop(ConflictChoice.useFile),
          child: Text(fileGone ? 'Discard changes' : 'Use the file'),
        ),
        FilledButton(
          key: const ValueKey('conflict_keep'),
          onPressed: () =>
              Navigator.of(context).pop(ConflictChoice.keepChanges),
          child: const Text('Keep my changes'),
        ),
      ],
    ),
  );
  return choice ?? ConflictChoice.keepChanges;
}

/// Asks to confirm something that replaces data. Dismissing says no.
Future<bool> askToConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => CfAlertDialog(
      key: const ValueKey('confirm_dialog'),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          key: const ValueKey('confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('confirm_ok'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Asks for a workspace-relative file path, checked as it is typed; null
/// when cancelled.
Future<String?> askFilePath(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initialPath = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _FilePathDialog(
      title: title,
      confirmLabel: confirmLabel,
      initialPath: initialPath,
    ),
  );
}

class _FilePathDialog extends StatefulWidget {
  const _FilePathDialog({
    required this.title,
    required this.confirmLabel,
    required this.initialPath,
  });

  final String title;
  final String confirmLabel;
  final String initialPath;

  @override
  State<_FilePathDialog> createState() => _FilePathDialogState();
}

class _FilePathDialogState extends State<_FilePathDialog> {
  late final TextEditingController _path = TextEditingController(
    text: widget.initialPath,
  );
  String? _problem;

  @override
  void initState() {
    super.initState();
    // Select the name without its extension, as desktop editors do, so
    // typing replaces just that.
    final path = widget.initialPath;
    final name = pathBaseName(path);
    final start = path.length - name.length;
    final dot = name.lastIndexOf('.');
    _path.selection = TextSelection(
      baseOffset: start,
      extentOffset: dot > 0 ? start + dot : path.length,
    );
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _submit() {
    final path = _path.text.trim();
    final problem = workspacePathProblem(path);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop(path);
  }

  @override
  Widget build(BuildContext context) {
    return CfAlertDialog(
      key: const ValueKey('file_path_dialog'),
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('file_path_field'),
        controller: _path,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Path in the workspace',
          hintText: 'src/app.js',
          errorText: _problem,
          errorMaxLines: 3,
        ),
        onChanged: (_) {
          if (_problem != null) {
            setState(() => _problem = null);
          }
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          key: const ValueKey('file_path_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('file_path_confirm'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
