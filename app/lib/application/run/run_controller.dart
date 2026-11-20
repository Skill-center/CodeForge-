/// Run (Phase 5 W4; docs/TERMINAL_ARCHITECTURE.md §3): Run Current File,
/// Run Project and Stop. Each run is a terminal session
/// ([TerminalController.run]), shown in the panel: in the project's folder,
/// or for a folder from shared storage in its copy (ADR-0013), which is
/// brought up to date first. This keeps the runs, newest first, with how
/// each is going as its session reports it, and for a folder's run the
/// files it made, which the user exports. Unsaved changes are saved first,
/// unless the user turned that off (Settings).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_location.dart';
import '../../core/logging/logger.dart';
import '../../core/run/run_commands.dart';
import '../../core/terminal/terminal_models.dart';
import '../../services/files/storage_broker.dart';
import '../../services/shell/shell_state.dart';
import '../documents/document_controller.dart';
import '../providers.dart';
import '../runtime_controller.dart';
import '../settings_controller.dart';
import '../shell_controller.dart';
import '../terminal/terminal_controller.dart';

const String _tag = 'run';

/// The most runs the Run panel keeps.
const int maxRunRecords = 30;

/// What Run says of a file it cannot run.
const String notRunnableMessage =
    'Run runs JavaScript, Python, shell, Ruby and Perl files.';

/// The copy a folder's run ran in: the folder, and how the copy went.
final class RunCopy {
  const RunCopy({
    required this.copyId,
    required this.treeUri,
    required this.summary,
  });

  final String copyId;

  /// The folder's grant, for export.
  final String treeUri;
  final CopySummary summary;
}

/// One run: what ran, in which session, and how it went.
final class RunRecord {
  const RunRecord({
    required this.sessionId,
    required this.command,
    required this.workspaceId,
    required this.started,
    this.copy,
    this.state = TerminalSessionState.starting,
    this.exitCode,
    this.signal,
    this.closed = false,
  });

  final int sessionId;
  final RunCommand command;

  /// The workspace it ran in.
  final String workspaceId;
  final DateTime started;

  /// The folder's copy it ran in; null in a project.
  final RunCopy? copy;
  final TerminalSessionState state;
  final int? exitCode;
  final int? signal;

  /// Its terminal tab was closed; the record keeps how it ended.
  final bool closed;

  bool get running => state != TerminalSessionState.exited && !closed;

  /// What its status chip says: `Running`, `Exit 0`, `Signal 15`, `Ended`.
  String get status {
    if (running) {
      return 'Running';
    }
    if (exitCode != null) {
      return 'Exit $exitCode';
    }
    if (signal != null) {
      return 'Signal $signal';
    }
    return 'Ended';
  }

  RunRecord copyWith({
    TerminalSessionState? state,
    int? exitCode,
    int? signal,
    bool? closed,
  }) {
    return RunRecord(
      sessionId: sessionId,
      command: command,
      workspaceId: workspaceId,
      started: started,
      copy: copy,
      state: state ?? this.state,
      exitCode: exitCode ?? this.exitCode,
      signal: signal ?? this.signal,
      closed: closed ?? this.closed,
    );
  }
}

/// What the Run panel and the status strip show.
final class RunState {
  const RunState({
    this.runs = const [],
    this.message,
    this.starting = false,
    this.copying,
  });

  /// Newest first.
  final List<RunRecord> runs;

  /// The last thing that went wrong, or worth saying, for the workbench.
  final String? message;

  /// A run is being saved for, copied for and started.
  final bool starting;

  /// A folder is being copied for a run: how far it is.
  final CopyProgress? copying;

  RunRecord? get latest => runs.isEmpty ? null : runs.first;

  static const Object _keep = Object();

  RunState copyWith({
    List<RunRecord>? runs,
    Object? message = _keep,
    bool? starting,
    Object? copying = _keep,
  }) {
    return RunState(
      runs: runs ?? this.runs,
      message: identical(message, _keep) ? this.message : message as String?,
      starting: starting ?? this.starting,
      copying: identical(copying, _keep)
          ? this.copying
          : copying as CopyProgress?,
    );
  }
}

/// "1.2 MB": a size for people.
String sizeLabel(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
  }
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

String _files(int count) => count == 1 ? '1 file' : '$count files';

/// How a folder's copy went, in a line: what it copied, kept and removed.
String copySummaryLine(CopySummary summary) {
  final parts = <String>[
    summary.copied == 0
        ? 'nothing new to copy'
        : '${_files(summary.copied)} copied (${sizeLabel(summary.bytesCopied)})',
    if (summary.unchanged > 0) '${summary.unchanged} unchanged',
    if (summary.removed > 0) '${summary.removed} removed',
  ];
  final seconds = summary.elapsed.inMilliseconds / 1000;
  return 'In the folder’s copy: ${parts.join(', ')}, '
      'in ${seconds.toStringAsFixed(1)} s';
}

/// What the copy left out, or null when it took everything but `.git`.
String? copyLeftOutLine(CopySummary summary) {
  final parts = <String>[
    if (summary.leftOutLarge > 0) '${_files(summary.leftOutLarge)} over 64 MB',
    if (summary.leftOutFull > 0)
      '${summary.capped ? 'at least ' : ''}'
          '${_files(summary.leftOutFull)} past the copy’s limit '
          '(10,000 files, 512 MB)',
    if (summary.leftOutVirtual > 0)
      '${_files(summary.leftOutVirtual)} with no bytes (online documents)',
    if (summary.leftOutDeep > 0)
      '${summary.leftOutDeep == 1 ? '1 folder' : '${summary.leftOutDeep} '
                'folders'} nested too deep',
    if (summary.unreadable > 0) '${summary.unreadable} that could not be read',
  ];
  if (parts.isEmpty) {
    return null;
  }
  return 'The copy left out ${parts.join(', ')}. Import the folder as a '
      'project to run it whole.';
}

final class RunController extends Notifier<RunState> {
  /// Following the terminals' tabs, from the first run on: before it the
  /// terminal panel (and its page) need not exist.
  ProviderSubscription<TerminalPanelState>? _tabs;

  @override
  RunState build() {
    _tabs = null;
    return const RunState();
  }

  /// Run Current File: [path] (a workspace path) with its program.
  Future<void> runFile(String path) async {
    final document = ref.read(documentControllerProvider).documents[path];
    final command = runCommandForFile(
      path,
      firstLine: document == null ? null : firstLineOf(document.savedText),
    );
    if (command == null) {
      _say(notRunnableMessage);
      return;
    }
    await runCommand(command);
  }

  /// Runs [command] in the open workspace, in a terminal of its own: in a
  /// project's folder, or in a folder's copy once it is up to date.
  Future<void> runCommand(RunCommand command) async {
    if (state.starting) {
      return;
    }
    final workspace = ref.read(currentWorkspaceProvider);
    if (!ref.read(runtimeControllerProvider).usable) {
      _say('The Linux runtime is not ready yet.');
      return;
    }
    state = state.copyWith(starting: true, message: null);
    try {
      if (ref.read(settingsControllerProvider).saveBeforeRun) {
        final problem = await _saveAll();
        if (problem != null) {
          _say(problem);
          return;
        }
      }
      String? project;
      RunCopy? copy;
      switch (workspace) {
        case ProjectLocation(:final folder):
          project = folder;
        case final FolderLocation folder:
          copy = await _syncCopy(folder);
          if (copy == null) {
            return;
          }
      }
      final shell = ref.read(shellControllerProvider);
      if (shell.terminalStop == TerminalStop.closed) {
        ref
            .read(shellControllerProvider.notifier)
            .setTerminalStop(TerminalStop.half);
      }
      final started = await ref
          .read(terminalControllerProvider.notifier)
          .run(
            TerminalSpec(
              project: project,
              copy: copy?.copyId,
              program: command.program,
              arguments: command.arguments,
              label: command.title,
            ),
          );
      switch (started) {
        case Err(:final failure):
          _say(failure.message);
        case Ok(:final value):
          appLogger.info(
            _tag,
            'started',
            fields: {
              'session': value,
              'program': command.program,
              'copy': copy != null,
            },
          );
          final record = RunRecord(
            sessionId: value,
            command: command,
            workspaceId: workspace.id,
            started: DateTime.now(),
            copy: copy,
          );
          state = state.copyWith(
            runs: [record, ...state.runs].take(maxRunRecords).toList(),
          );
          _tabs ??= ref.listen<TerminalPanelState>(
            terminalControllerProvider,
            (_, panel) => _sync(panel),
          );
          _sync(ref.read(terminalControllerProvider));
          final leftOut = copy == null ? null : copyLeftOutLine(copy.summary);
          if (leftOut != null) {
            _say(leftOut);
          }
      }
    } finally {
      state = state.copyWith(starting: false, copying: null);
    }
  }

  /// Runs [run]'s command again.
  Future<void> rerun(RunRecord run) => runCommand(run.command);

  /// Stop: ends run [sessionId]'s session with everything it started
  /// (`SIGTERM`, then `SIGKILL` after the grace period). Its tab and its
  /// output stay.
  Future<void> stop(int sessionId) async {
    final ended = await ref
        .read(terminalControllerProvider.notifier)
        .end(sessionId);
    if (ended case Err(:final failure)) {
      _say(failure.message);
    }
  }

  /// Stops the newest run that is still running, if any.
  Future<void> stopLatest() async {
    for (final run in state.runs) {
      if (run.running) {
        await stop(run.sessionId);
        return;
      }
    }
  }

  /// Stops the folder copy under way between files; nothing runs.
  Future<void> cancelCopy() async {
    final copying = state.copying;
    if (copying != null) {
      await ref.read(storageBrokerProvider).cancelCopy(copying.copyId);
    }
  }

  /// What Run Project offers in the open workspace: its `package.json`'s
  /// scripts, then its entry file.
  Future<List<RunCommand>> projectRuns() async {
    final files = ref.read(fileServiceProvider);
    final listing = await files.listDirectory('');
    final names = switch (listing) {
      Ok(:final value) => [
        for (final entry in value)
          if (!entry.isDirectory) entry.name,
      ],
      Err() => const <String>[],
    };
    String? manifest;
    if (names.contains('package.json')) {
      final read = await files.readText('package.json');
      if (read case Ok(:final value)) {
        manifest = value.text;
      }
    }
    return projectRunsFrom(packageJson: manifest, rootFiles: names);
  }

  /// The files [run] and the runs before it created or changed in the
  /// folder's copy.
  Future<Result<CopyChanges>> changes(RunRecord run) {
    final copy = run.copy;
    if (copy == null) {
      return Future.value(const Ok(CopyChanges()));
    }
    return ref.read(storageBrokerProvider).copyChanges(copy.copyId);
  }

  /// Writes the copy's files at [paths] back to [run]'s folder.
  Future<Result<ExportResult>> export(RunRecord run, List<String> paths) async {
    final copy = run.copy;
    if (copy == null || paths.isEmpty) {
      return const Ok(ExportResult(exported: 0));
    }
    final result = await ref
        .read(storageBrokerProvider)
        .exportCopy(copy.treeUri, copy.copyId, paths);
    if (result case Ok(:final value)) {
      appLogger.info(
        _tag,
        'exported',
        fields: {'files': value.exported, 'failed': value.failures.length},
      );
    }
    return result;
  }

  void dismissMessage() => state = state.copyWith(message: null);

  /// Brings [folder]'s copy up to date, with its progress in [RunState];
  /// null when it failed or was cancelled (and said so).
  Future<RunCopy?> _syncCopy(FolderLocation folder) async {
    final broker = ref.read(storageBrokerProvider);
    state = state.copyWith(
      copying: CopyProgress(copyId: folder.id, files: 0, bytes: 0),
    );
    final progress = broker.copyProgress
        .where((p) => p.copyId == folder.id)
        .listen((p) {
          if (state.copying != null) {
            state = state.copyWith(copying: p);
          }
        });
    try {
      final synced = await broker.syncCopy(folder.treeUri, folder.id);
      switch (synced) {
        case Err(:final failure):
          _say(
            'The folder could not be copied for the run: ${failure.message}',
          );
          return null;
        case Ok(:final value):
          appLogger.info(
            _tag,
            'copied',
            fields: {
              'files': value.files,
              'copied': value.copied,
              'unchanged': value.unchanged,
              'removed': value.removed,
              'leftOut': value.leftOut,
              'ms': value.elapsed.inMilliseconds,
            },
          );
          if (value.stopped) {
            _say('The copy was cancelled, so nothing ran.');
            return null;
          }
          return RunCopy(
            copyId: folder.id,
            treeUri: folder.treeUri,
            summary: value,
          );
      }
    } finally {
      await progress.cancel();
      state = state.copyWith(copying: null);
    }
  }

  /// Saves every open document with unsaved changes; answers what went
  /// wrong, or null.
  Future<String?> _saveAll() async {
    final documents = ref.read(documentControllerProvider);
    final notifier = ref.read(documentControllerProvider.notifier);
    for (final path in documents.openPaths) {
      final document = documents.documents[path];
      if (document == null || !document.dirty) {
        continue;
      }
      final saved = await notifier.save(path);
      if (saved case Err(:final failure)) {
        return 'Could not save ${document.name} before the run: '
            '${failure.message}';
      }
    }
    return null;
  }

  /// Each run follows its session's tab: running, exited, or closed.
  void _sync(TerminalPanelState panel) {
    if (state.runs.isEmpty) {
      return;
    }
    final tabs = {for (final tab in panel.tabs) tab.sessionId: tab};
    var changed = false;
    final runs = <RunRecord>[];
    for (final run in state.runs) {
      final tab = tabs[run.sessionId];
      final next = tab == null
          ? run.copyWith(closed: true)
          : RunRecord(
              sessionId: run.sessionId,
              command: run.command,
              workspaceId: run.workspaceId,
              started: run.started,
              copy: run.copy,
              state: tab.state,
              exitCode: tab.exitCode,
              signal: tab.signal,
            );
      if (next.closed != run.closed ||
          next.state != run.state ||
          next.exitCode != run.exitCode ||
          next.signal != run.signal) {
        changed = true;
        runs.add(next);
      } else {
        runs.add(run);
      }
    }
    if (changed) {
      state = state.copyWith(runs: runs);
    }
  }

  void _say(String message) => state = state.copyWith(message: message);
}

final runControllerProvider = NotifierProvider<RunController, RunState>(
  RunController.new,
);
