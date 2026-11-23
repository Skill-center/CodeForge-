/// Rename (Phase 6 W5, PHASE_6_PLAN W5): the dialog for the new name,
/// filled in from the server's `prepareRename`, then the rename across
/// files, all or nothing (application/lsp/rename.dart), and its summary.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/lsp/lsp_features.dart';
import '../../application/lsp/rename.dart';
import '../../core/errors/failure.dart';
import '../../design_system/components/dialogs.dart';

/// Why [name] can't be the new name for [oldName], or null when it can.
/// The server judges the rest (a keyword, a clash) and says so.
String? newNameProblem(String name, String oldName) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return 'Type the new name.';
  }
  if (trimmed == oldName) {
    return 'That is its name now.';
  }
  if (RegExp(r'\s').hasMatch(trimmed)) {
    return 'A name has no spaces or line breaks.';
  }
  return null;
}

/// Asks the new name for [request]'s symbol; null when the user backs out.
Future<String?> askNewName(BuildContext context, RenameRequest request) {
  return showDialog<String>(
    context: context,
    builder: (context) => RenameDialog(request: request),
  );
}

class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key, required this.request});

  final RenameRequest request;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _input =
      TextEditingController(text: widget.request.placeholder)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.request.placeholder.length,
        );
  String? _problem;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = newNameProblem(_input.text, widget.request.oldName);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop(_input.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    return CfAlertDialog(
      key: const ValueKey('rename_dialog'),
      title: Text('Rename ${request.oldName}'),
      content: TextField(
        key: const ValueKey('rename_field'),
        controller: _input,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'New name',
          helperText:
              '${request.server.title} renames it in every file that uses it',
          helperMaxLines: 2,
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
          key: const ValueKey('rename_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('rename_confirm'),
          onPressed: _submit,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// The rename the page asked for: the new name, then the rename, then what
/// it changed, or why nothing was.
Future<void> renameSymbol(
  BuildContext context,
  WidgetRef ref,
  RenameRequest request,
) async {
  final name = await askNewName(context, request);
  if (name == null || !context.mounted) {
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final result = await ref
      .read(lspFeaturesProvider.notifier)
      .rename(request, name);
  final message = switch (result) {
    Ok<RenameSummary>(:final value) => value.message,
    Err<RenameSummary>(:final failure) => failure.message,
  };
  messenger.showSnackBar(
    SnackBar(
      key: const ValueKey('rename_summary'),
      content: Text(message),
      duration: const Duration(seconds: 6),
    ),
  );
}
