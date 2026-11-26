/// What the Source control panel asks before it changes something
/// (Phase 7 W4, PHASE_7_PLAN W4): a new branch's name, a commit's files,
/// and the confirmations for what cannot be undone.
///
/// Every confirmation names what it is about — the file whose changes go,
/// the branch that is deleted — because a tap in a list is easy to make by
/// mistake. The branch dialog checks the name with git itself
/// (`check-ref-format`) before it closes, so the reason comes from git and
/// not from a guess here.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/errors/failure.dart';
import '../../core/git/git_models.dart';
import '../../design_system/components/dialogs.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';

/// The words for discarding [path]'s changes: what goes, and that it stays
/// gone. An untracked file is deleted instead, which the words say.
({String title, String message, String confirmLabel}) discardWords(
  GitFileStatus file,
) => file.untracked
    ? (
        title: 'Delete ${_name(file.path)}?',
        message:
            'Git does not know ${file.path} yet, so deleting it here loses '
            'it. This cannot be undone.',
        confirmLabel: 'Delete',
      )
    : (
        title: 'Discard changes to ${_name(file.path)}?',
        message:
            'The changes in ${file.path} that are not staged go back to '
            'what is staged. This cannot be undone.',
        confirmLabel: 'Discard',
      );

String _name(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// Asks for a new branch's name, from [from] (`main`, a short commit).
/// [submit] checks the name — git's own check, then the branch — and
/// returns what went wrong, or null when the branch was made. Null when
/// the dialog was cancelled.
Future<String?> askNewBranch(
  BuildContext context, {
  required String from,
  required Future<String?> Function(String name) submit,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _NewBranchDialog(from: from, submit: submit),
  );
}

class _NewBranchDialog extends StatefulWidget {
  const _NewBranchDialog({required this.from, required this.submit});

  final String from;
  final Future<String?> Function(String name) submit;

  @override
  State<_NewBranchDialog> createState() => _NewBranchDialogState();
}

class _NewBranchDialogState extends State<_NewBranchDialog> {
  final TextEditingController _name = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'new branch');
  String? _problem;
  bool _running = false;

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _problem = 'Enter a name for the branch.');
      return;
    }
    setState(() {
      _running = true;
      _problem = null;
    });
    final problem = await widget.submit(name);
    if (!mounted) {
      return;
    }
    if (problem == null) {
      Navigator.of(context).pop(name);
      return;
    }
    setState(() {
      _running = false;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return CfAlertDialog(
      key: const ValueKey('git_branch_dialog'),
      title: const Text('New branch'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'From ${widget.from}. The new branch is checked out.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: CfSpacing.md),
          TextField(
            key: const ValueKey('git_branch_name'),
            controller: _name,
            focusNode: _focus,
            autofocus: true,
            enabled: !_running,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'feature/login',
            ),
            onChanged: (_) {
              if (_problem != null) {
                setState(() => _problem = null);
              }
            },
            onSubmitted: (_) => unawaited(_create()),
          ),
          if (_problem case final problem?) ...[
            const SizedBox(height: CfSpacing.sm),
            Text(
              problem,
              key: const ValueKey('git_branch_problem'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('git_branch_cancel'),
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('git_branch_create'),
          onPressed: _running ? null : () => unawaited(_create()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Shows what [commit] changed: its message, who made it and when, and the
/// files, each with its change. A tap on a file opens it through [onFile]
/// (Phase 7 W5 shows that file's diff there instead).
Future<void> showCommitSheet(
  BuildContext context, {
  required GitCommit commit,
  required Future<Result<List<GitCommitFile>>> Function() files,
  required void Function(GitCommitFile file) onFile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) =>
        _CommitSheet(commit: commit, files: files, onFile: onFile),
  );
}

class _CommitSheet extends StatefulWidget {
  const _CommitSheet({
    required this.commit,
    required this.files,
    required this.onFile,
  });

  final GitCommit commit;
  final Future<Result<List<GitCommitFile>>> Function() files;
  final void Function(GitCommitFile file) onFile;

  @override
  State<_CommitSheet> createState() => _CommitSheetState();
}

class _CommitSheetState extends State<_CommitSheet> {
  List<GitCommitFile>? _files;
  String? _problem;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final result = await widget.files();
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<List<GitCommitFile>>(:final value):
        setState(() => _files = value);
      case Err<List<GitCommitFile>>(:final failure):
        setState(() => _problem = failure.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final commit = widget.commit;
    final files = _files;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          CfSpacing.lg,
          0,
          CfSpacing.lg,
          CfSpacing.lg,
        ),
        child: Column(
          key: const ValueKey('git_commit_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(commit.subject, style: textTheme.titleSmall),
            const SizedBox(height: CfSpacing.xs),
            Text(
              '${commit.shortHash} · ${commit.authorName} · '
              '${describeCommitDate(commit.authoredAt)}',
              style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: CfSpacing.md),
            if (_problem case final problem?)
              Text(
                problem,
                key: const ValueKey('git_commit_sheet_problem'),
                style: textTheme.bodySmall?.copyWith(color: colors.danger),
              )
            else if (files == null)
              const Padding(
                padding: EdgeInsets.all(CfSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (files.isEmpty)
              Text(
                'This commit changed no files.',
                style: textTheme.bodySmall,
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    final file = files[index];
                    return InkWell(
                      key: ValueKey('git_commit_file_${file.path}'),
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.onFile(file);
                      },
                      child: Container(
                        constraints: const BoxConstraints(
                          minHeight: CfSpacing.minTouchTarget,
                        ),
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 20,
                              child: Text(
                                file.change.letter,
                                style: textTheme.labelSmall?.copyWith(
                                  color: colors.textSecondary,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                file.originalPath == null
                                    ? file.path
                                    : '${file.originalPath} → ${file.path}',
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodySmall,
                              ),
                            ),
                            Icon(
                              CfIcons.chevronRight,
                              size: 16,
                              color: colors.textDisabled,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A commit's date, short and plain: `2026-11-05 14:03`, in local time.
String describeCommitDate(DateTime when) {
  final local = when.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
