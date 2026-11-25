/// Home → Clone repository (Phase 7 W3, PHASE_7_PLAN W3): a URL and the
/// new project's name, then the clone as it goes, with Stop. The workbench
/// shows fetch, pull and push the same way ([showGitProgress]).
///
/// The URL is checked before anything runs (core/git/git_urls.dart): HTTPS
/// or SSH, and never a password or a token in it, which CodeForge asks for
/// instead. The clone goes into a hidden folder and is renamed into place
/// when git succeeds, so Stop or a failure leaves nothing behind.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/errors/failure.dart';
import '../../core/files/workspace_location.dart';
import '../../core/git/git_models.dart';
import '../../core/git/git_urls.dart';
import '../../design_system/components/dialogs.dart';

/// What the clone dialog asked for.
final class CloneRequest {
  const CloneRequest({required this.url, required this.name});

  final String url;
  final String name;
}

/// Asks for a repository's URL and the project's name; null when
/// cancelled. [taken] holds the project folders that exist.
Future<CloneRequest?> askClone(
  BuildContext context, {
  required List<String> taken,
}) => showDialog<CloneRequest>(
  context: context,
  builder: (context) => CloneDialog(taken: taken),
);

class CloneDialog extends StatefulWidget {
  const CloneDialog({super.key, required this.taken});

  final List<String> taken;

  @override
  State<CloneDialog> createState() => _CloneDialogState();
}

class _CloneDialogState extends State<CloneDialog> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _name = TextEditingController();

  /// The name follows the URL until the user types one.
  bool _nameTyped = false;
  String? _urlProblem;
  String? _nameProblem;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  void _urlChanged(String text) {
    setState(() {
      _urlProblem = null;
      if (!_nameTyped) {
        _name.text = projectNameFromUrl(text) ?? '';
      }
    });
  }

  void _submit() {
    final url = _url.text.trim();
    final name = _name.text.trim();
    final urlProblem = checkRemoteUrl(url).problem?.message;
    final nameProblem = urlProblem == null
        ? projectNameProblem(name, taken: widget.taken)
        : null;
    if (urlProblem != null || nameProblem != null) {
      setState(() {
        _urlProblem = urlProblem;
        _nameProblem = nameProblem;
      });
      return;
    }
    Navigator.of(context).pop(CloneRequest(url: url, name: name));
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return CfAlertDialog(
      key: const ValueKey('clone_dialog'),
      title: const Text('Clone repository'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'An HTTPS or SSH URL. CodeForge asks for a token when the host '
            'wants one, and can remember it on this device.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('clone_url'),
            controller: _url,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Repository URL',
              hintText: 'https://github.com/owner/repo.git',
              errorText: _urlProblem,
              errorMaxLines: 4,
            ),
            onChanged: _urlChanged,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('clone_name'),
            controller: _name,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Project name',
              errorText: _nameProblem,
              errorMaxLines: 3,
            ),
            onChanged: (_) => setState(() {
              _nameTyped = true;
              _nameProblem = null;
            }),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('clone_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('clone_confirm'),
          onPressed: _submit,
          child: const Text('Clone'),
        ),
      ],
    );
  }
}

/// Shows a remote operation as it goes ([title]: "Cloning repo"), with its
/// progress and Stop, while [run] runs; closes when it ends, and answers
/// what it answered. [run] gets the progress callback and the stop signal.
Future<Result<void>> showGitProgress(
  BuildContext context, {
  required String title,
  required Future<Result<void>> Function(
    void Function(GitProgress progress) onProgress,
    Future<void> stop,
  )
  run,
}) async {
  final stop = Completer<void>();
  // Not broadcast: what comes before the dialog listens waits for it.
  final progress = StreamController<GitProgress>();
  final work = run(progress.add, stop.future);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => GitProgressDialog(
      title: title,
      work: work,
      progress: progress.stream,
      onStop: () {
        if (!stop.isCompleted) {
          stop.complete();
        }
      },
    ),
  );
  unawaited(progress.close());
  return work;
}

class GitProgressDialog extends StatefulWidget {
  const GitProgressDialog({
    super.key,
    required this.title,
    required this.work,
    required this.progress,
    required this.onStop,
  });

  final String title;
  final Future<Result<void>> work;
  final Stream<GitProgress> progress;
  final VoidCallback onStop;

  @override
  State<GitProgressDialog> createState() => _GitProgressDialogState();
}

class _GitProgressDialogState extends State<GitProgressDialog> {
  late final StreamSubscription<GitProgress> _progress;
  GitProgress? _last;
  bool _stopping = false;

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
    final percent = last?.percent;
    final words = _stopping
        ? 'Stopping…'
        : last == null
        ? 'Connecting…'
        : [
            last.phase,
            if (percent != null) '$percent%',
            if (last.done != null && last.total != null)
              '(${last.done}/${last.total})',
          ].join(' ');
    return PopScope<Object?>(
      canPop: false,
      child: CfAlertDialog(
        key: const ValueKey('git_progress_dialog'),
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(
              value: percent == null || _stopping ? null : percent / 100,
            ),
            const SizedBox(height: 12),
            Text(
              words,
              key: const ValueKey('git_progress_text'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('git_progress_stop'),
            onPressed: _stopping
                ? null
                : () {
                    setState(() => _stopping = true);
                    widget.onStop();
                  },
            child: const Text('Stop'),
          ),
        ],
      ),
    );
  }
}
