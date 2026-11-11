/// Home's dialogs (Phase 3 W3): a project's name, new or changed, and the
/// questions before a project is deleted, a folder leaves the recents or
/// a reconnected folder replaces an entry.
library;

import 'package:flutter/material.dart';

import '../../core/files/workspace_location.dart';
import '../../design_system/components/dialogs.dart';

/// What the new-project dialog asked for.
final class NewProject {
  const NewProject({required this.name, required this.fromTemplate});

  final String name;

  /// Start with the demo project's files rather than nothing.
  final bool fromTemplate;
}

/// Asks for a new project's name, and whether it starts from the demo
/// project's files; null when cancelled. [taken] holds the project
/// folders that exist.
Future<NewProject?> askNewProject(
  BuildContext context, {
  required List<String> taken,
}) {
  return showDialog<NewProject>(
    context: context,
    builder: (context) => _ProjectNameDialog(
      title: 'New project',
      confirmLabel: 'Create',
      taken: taken,
      offerTemplate: true,
    ),
  );
}

/// Asks for a project's new name; null when cancelled or unchanged.
Future<String?> askProjectName(
  BuildContext context, {
  required String current,
  required List<String> taken,
}) async {
  final answer = await showDialog<NewProject>(
    context: context,
    builder: (context) => _ProjectNameDialog(
      title: 'Rename project',
      confirmLabel: 'Rename',
      initialName: current,
      taken: [
        for (final folder in taken)
          if (folder != current) folder,
      ],
      offerTemplate: false,
    ),
  );
  final name = answer?.name;
  return name == null || name == current ? null : name;
}

/// Asks to confirm something that cannot be undone. Dismissing says no.
Future<bool> askHomeConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => CfAlertDialog(
      key: const ValueKey('home_confirm_dialog'),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          key: const ValueKey('home_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('home_confirm_ok'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// "N files", "1 file".
String countOf(int count, String noun) =>
    count == 1 ? '1 $noun' : '$count ${noun}s';

class _ProjectNameDialog extends StatefulWidget {
  const _ProjectNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.taken,
    required this.offerTemplate,
    this.initialName = '',
  });

  final String title;
  final String confirmLabel;
  final List<String> taken;
  final bool offerTemplate;
  final String initialName;

  @override
  State<_ProjectNameDialog> createState() => _ProjectNameDialogState();
}

class _ProjectNameDialogState extends State<_ProjectNameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  )..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialName.length,
    );
  String? _problem;
  bool _fromTemplate = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text;
    final problem = projectNameProblem(name, taken: widget.taken);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(
      context,
    ).pop(NewProject(name: name, fromTemplate: _fromTemplate));
  }

  @override
  Widget build(BuildContext context) {
    return CfAlertDialog(
      key: const ValueKey('project_name_dialog'),
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('project_name_field'),
            controller: _name,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Project name',
              hintText: 'my-app',
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
          if (widget.offerTemplate)
            SwitchListTile(
              key: const ValueKey('project_template'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Start from the demo project'),
              subtitle: const Text('JavaScript, Python and Dart samples'),
              value: _fromTemplate,
              onChanged: (value) => setState(() => _fromTemplate = value),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('project_name_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('project_name_confirm'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
