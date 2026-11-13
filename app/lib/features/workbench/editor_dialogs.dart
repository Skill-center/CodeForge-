/// Dialogs of the workbench's editing flows (editor_actions.dart).
library;

import 'package:material_ui/material_ui.dart';

import '../../core/editor/line_target.dart';
import '../../design_system/components/dialogs.dart';

/// Asks where to move the cursor in a document of [lineCount] lines; null
/// when cancelled.
Future<LineTarget?> askLineTarget(
  BuildContext context, {
  required int lineCount,
  required int currentLine,
}) {
  return showDialog<LineTarget>(
    context: context,
    builder: (context) =>
        _GoToLineDialog(lineCount: lineCount, currentLine: currentLine),
  );
}

class _GoToLineDialog extends StatefulWidget {
  const _GoToLineDialog({required this.lineCount, required this.currentLine});

  final int lineCount;
  final int currentLine;

  @override
  State<_GoToLineDialog> createState() => _GoToLineDialogState();
}

class _GoToLineDialogState extends State<_GoToLineDialog> {
  final TextEditingController _input = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = parseLineTarget(_input.text, lineCount: widget.lineCount);
    final target = parsed.target;
    if (target == null) {
      setState(() => _problem = parsed.problem);
      return;
    }
    Navigator.of(context).pop(target);
  }

  @override
  Widget build(BuildContext context) {
    return CfAlertDialog(
      key: const ValueKey('goto_line_dialog'),
      title: const Text('Go to line'),
      content: TextField(
        key: const ValueKey('goto_line_field'),
        controller: _input,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        // The number pad, with its decimal key as the column separator.
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.go,
        decoration: InputDecoration(
          labelText: 'Line, or line:column',
          hintText: '1 to ${widget.lineCount}',
          helperText: 'Now on line ${widget.currentLine}',
          errorText: _problem,
          errorMaxLines: 2,
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
          key: const ValueKey('goto_line_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('goto_line_confirm'),
          onPressed: _submit,
          child: const Text('Go'),
        ),
      ],
    );
  }
}
