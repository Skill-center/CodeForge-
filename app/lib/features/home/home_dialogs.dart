/// Home's dialogs (Phase 3 W3): a project's name, new or changed, and the
/// questions before a project is deleted, a folder leaves the recents or
/// a reconnected folder replaces an entry; since Phase 5 W4 the name a
/// folder is imported as, and the import as it goes.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/files/workspace_location.dart';
import '../../design_system/components/dialogs.dart';
import '../../services/files/storage_broker.dart';

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

/// Asks for the name of the project [folderName] is imported as (Phase 5
/// W4); null when cancelled.
Future<String?> askImportName(
  BuildContext context, {
  required String folderName,
  required List<String> taken,
}) async {
  final answer = await showDialog<NewProject>(
    context: context,
    builder: (context) => _ProjectNameDialog(
      title: 'Import as project',
      confirmLabel: 'Import',
      initialName: importNameFor(folderName, taken: taken),
      taken: taken,
      offerTemplate: false,
      note:
          'Copies the whole folder, git’s files included, into a new '
          'project on this device. Run, the terminal and search then work '
          'on all of it. The folder itself stays as it is.',
    ),
  );
  return answer?.name;
}

/// Shows an import as it goes while [work] runs: the files copied so far
/// ([progress]) and Cancel ([onCancel]). Closes when [work] ends, and
/// answers what it answered.
Future<T> showImportProgress<T>(
  BuildContext context, {
  required String folderName,
  required Future<T> work,
  required Stream<CopyProgress> progress,
  required VoidCallback onCancel,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ImportProgressDialog(
      folderName: folderName,
      work: work,
      progress: progress,
      onCancel: onCancel,
    ),
  );
  return work;
}

class _ImportProgressDialog extends StatefulWidget {
  const _ImportProgressDialog({
    required this.folderName,
    required this.work,
    required this.progress,
    required this.onCancel,
  });

  final String folderName;
  final Future<Object?> work;
  final Stream<CopyProgress> progress;
  final VoidCallback onCancel;

  @override
  State<_ImportProgressDialog> createState() => _ImportProgressDialogState();
}

class _ImportProgressDialogState extends State<_ImportProgressDialog> {
  late final StreamSubscription<CopyProgress> _progress;
  CopyProgress? _last;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _progress = widget.progress.listen((p) => setState(() => _last = p));
    unawaited(
      widget.work.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (mounted) {
          Navigator.of(context).pop();
        }
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_progress.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _last;
    final megabytes = last == null ? 0 : last.bytes / (1024 * 1024);
    return PopScope<Object?>(
      canPop: false,
      child: CfAlertDialog(
        key: const ValueKey('import_progress_dialog'),
        title: Text('Importing ${widget.folderName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _cancelling
                  ? 'Stopping…'
                  : last == null
                  ? 'Reading the folder…'
                  : '${last.files} files copied, '
                        '${megabytes.toStringAsFixed(1)} MB',
              key: const ValueKey('import_progress_text'),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('import_cancel'),
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    widget.onCancel();
                  },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
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
    this.note,
  });

  final String title;
  final String confirmLabel;
  final List<String> taken;
  final bool offerTemplate;
  final String initialName;

  /// Said above the name, when there is something to explain.
  final String? note;

  @override
  State<_ProjectNameDialog> createState() => _ProjectNameDialogState();
}

class _ProjectNameDialogState extends State<_ProjectNameDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName)
        ..selection = TextSelection(
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
          if (widget.note case final note?)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                note,
                key: const ValueKey('project_name_note'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
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
