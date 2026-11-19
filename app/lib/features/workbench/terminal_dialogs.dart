/// Dialogs of the terminal panel (Phase 5 W3): closing a session that still
/// runs, naming a tab, and ending every session.
library;

import 'package:material_ui/material_ui.dart';

import '../../design_system/components/dialogs.dart';

/// Asks before a running session is closed: closing ends it and everything
/// it started. True to close.
Future<bool> confirmCloseTerminal(BuildContext context, String label) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => CfAlertDialog(
      key: const ValueKey('terminal_close_dialog'),
      title: Text('Close $label?'),
      content: const Text(
        'It is still running. Closing it ends every program it started.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('terminal_close_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('terminal_close_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Close'),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// Asks before End all. True to end every session.
Future<bool> confirmEndAllTerminals(BuildContext context, int running) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => CfAlertDialog(
      key: const ValueKey('terminal_end_all_dialog'),
      title: const Text('End all terminals?'),
      content: Text(
        running == 1
            ? 'One terminal is running. Ending it ends every program it '
                  'started.'
            : '$running terminals are running. Ending them ends every '
                  'program they started.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('terminal_end_all_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('terminal_end_all_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('End all'),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// Asks for a tab's new name; null when cancelled, '' to give it back its
/// own.
Future<String?> askTerminalName(BuildContext context, String current) {
  return showDialog<String>(
    context: context,
    builder: (context) => _RenameDialog(current: current),
  );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});

  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _input =
      TextEditingController(text: widget.current)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.current.length,
        );

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_input.text.trim());

  @override
  Widget build(BuildContext context) {
    return CfAlertDialog(
      key: const ValueKey('terminal_rename_dialog'),
      title: const Text('Rename terminal'),
      content: TextField(
        key: const ValueKey('terminal_rename_field'),
        controller: _input,
        autofocus: true,
        autocorrect: false,
        maxLength: 40,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Name',
          helperText: 'Leave it empty for the terminal’s own name.',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          key: const ValueKey('terminal_rename_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('terminal_rename_confirm'),
          onPressed: _submit,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
