/// Run (Phase 5 W4; docs/TERMINAL_ARCHITECTURE.md §3): Run Current File,
/// Run Project and Stop. Each run is a terminal session
/// ([TerminalController.run]) in the project's folder, shown in the panel;
/// this keeps the runs, newest first, with how each is going as its session
/// reports it. Unsaved changes are saved first, unless the user turned that
/// off (Settings).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_location.dart';
import '../../core/logging/logger.dart';
import '../../core/run/run_commands.dart';
import '../../core/terminal/terminal_models.dart';
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

/// One run: what ran, in which session, and how it went.
final class RunRecord {
  const RunRecord({
    required this.sessionId,
    required this.command,
    required this.workspaceId,
    required this.started,
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
      state: state ?? this.state,
      exitCode: exitCode ?? this.exitCode,
      signal: signal ?? this.signal,
      closed: closed ?? this.closed,
    );
  }
}

/// What the Run panel and the status strip show.
final class RunState {
  const RunState({this.runs = const [], this.message, this.starting = false});

  /// Newest first.
  final List<RunRecord> runs;

  /// The last thing that went wrong, for the panel to say.
  final String? message;

  /// A run is being saved for and started.
  final bool starting;

  RunRecord? get latest => runs.isEmpty ? null : runs.first;

  static const Object _keep = Object();

  RunState copyWith({
    List<RunRecord>? runs,
    Object? message = _keep,
    bool? starting,
  }) {
    return RunState(
      runs: runs ?? this.runs,
      message: identical(message, _keep) ? this.message : message as String?,
      starting: starting ?? this.starting,
    );
  }
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

  /// Runs [command] in the open project's folder, in a terminal of its own.
  Future<void> runCommand(RunCommand command) async {
    if (state.starting) {
      return;
    }
    final workspace = ref.read(currentWorkspaceProvider);
    if (workspace is! ProjectLocation) {
      _say(
        'Run works in projects for now: a folder from shared storage runs '
        'through its copy, which comes next.',
      );
      return;
    }
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
              project: workspace.folder,
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
            fields: {'session': value, 'program': command.program},
          );
          final record = RunRecord(
            sessionId: value,
            command: command,
            workspaceId: workspace.id,
            started: DateTime.now(),
          );
          state = state.copyWith(
            runs: [record, ...state.runs].take(maxRunRecords).toList(),
          );
          _tabs ??= ref.listen<TerminalPanelState>(
            terminalControllerProvider,
            (_, panel) => _sync(panel),
          );
          _sync(ref.read(terminalControllerProvider));
      }
    } finally {
      state = state.copyWith(starting: false);
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

  /// What Run Project offers in the open project: its `package.json`'s
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

  void dismissMessage() => state = state.copyWith(message: null);

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
