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
/// when cancelled. With [submit] (Phase 3 W4) the dialog stays open until
/// [submit] accepts the path (returns null) or the user cancels, showing
/// what [submit] returned otherwise: a name that is taken asks for
/// another, and nothing is replaced. [folder] asks for a folder's path: a
/// slash at its end is dropped.
Future<String?> askFilePath(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initialPath = '',
  String hint = 'src/app.js',
  bool folder = false,
  Future<String?> Function(String path)? submit,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _TextEntryDialog(
      keyPrefix: 'file_path',
      title: title,
      confirmLabel: confirmLabel,
      initial: initialPath,
      label: 'Path in the workspace',
      hint: hint,
      check: workspacePathProblem,
      normalize: folder ? _dropTrailingSlashes : _same,
      submit: submit,
    ),
  );
}

/// Asks for a new name for [name] (Phase 3 W4: Rename), checked as it is
/// typed, with the part before a file's extension selected. The dialog
/// stays open until [submit] accepts the name (returns null) or the user
/// cancels. Null when cancelled.
Future<String?> askName(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required String name,
  required bool isFolder,
  required Future<String?> Function(String name) submit,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _TextEntryDialog(
      keyPrefix: 'name',
      title: title,
      confirmLabel: confirmLabel,
      initial: name,
      label: 'Name',
      hint: name,
      check: nameProblem,
      normalize: _same,
      submit: submit,
      wholeName: isFolder,
    ),
  );
}

String _same(String value) => value;

String _dropTrailingSlashes(String value) {
  var path = value;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

class _TextEntryDialog extends StatefulWidget {
  const _TextEntryDialog({
    required this.keyPrefix,
    required this.title,
    required this.confirmLabel,
    required this.initial,
    required this.label,
    required this.hint,
    required this.check,
    required this.normalize,
    this.submit,
    this.wholeName = false,
  });

  /// The keys' prefix: `<prefix>_dialog`, `_field`, `_cancel`, `_confirm`.
  final String keyPrefix;
  final String title;
  final String confirmLabel;
  final String initial;
  final String label;
  final String hint;

  /// Why the text is not acceptable, or null.
  final String? Function(String value) check;
  final String Function(String value) normalize;
  final Future<String?> Function(String value)? submit;

  /// Select the whole last name, not the part before its extension.
  final bool wholeName;

  @override
  State<_TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<_TextEntryDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Select the name without its extension, as desktop editors do, so
    // typing replaces just that.
    final value = widget.initial;
    final name = pathBaseName(value);
    final start = value.length - name.length;
    final dot = widget.wholeName ? -1 : name.lastIndexOf('.');
    _text.selection = TextSelection(
      baseOffset: start,
      extentOffset: dot > 0 ? start + dot : value.length,
    );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) {
      return;
    }
    final value = widget.normalize(_text.text.trim());
    final problem = widget.check(value);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    final submit = widget.submit;
    if (submit == null) {
      Navigator.of(context).pop(value);
      return;
    }
    setState(() => _busy = true);
    final refused = await submit(value);
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
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final prefix = widget.keyPrefix;
    return CfAlertDialog(
      key: ValueKey('${prefix}_dialog'),
      title: Text(widget.title),
      content: TextField(
        key: ValueKey('${prefix}_field'),
        controller: _text,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
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
          key: ValueKey('${prefix}_cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: ValueKey('${prefix}_confirm'),
          onPressed: _busy ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
