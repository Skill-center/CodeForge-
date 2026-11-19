/// The Run panel (Phase 5 W4; docs/TERMINAL_ARCHITECTURE.md §3): Run
/// Current File and Run Project, then the runs, newest first. Each run is a
/// terminal session (application/run/run_controller.dart) and has its
/// status chip (running, the exit code, or the signal that ended it), Stop
/// while it runs, Run again, and a way to its terminal. What Run could not
/// do, the workbench says (workbench_screen.dart).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../application/documents/document_controller.dart';
import '../../../application/run/run_controller.dart';
import '../../../application/runtime_controller.dart';
import '../../../application/shell_controller.dart';
import '../../../application/terminal/terminal_controller.dart';
import '../../../core/files/text_codec.dart';
import '../../../core/run/run_commands.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/dialogs.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/icons.dart';
import '../../../services/shell/shell_state.dart';

class RunPanel extends ConsumerWidget {
  const RunPanel({super.key, this.onRunStarted});

  /// Runs once a run started (the phone's sheet closes to show it).
  final VoidCallback? onRunStarted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final run = ref.watch(runControllerProvider);
    final controller = ref.read(runControllerProvider.notifier);
    final current = ref.watch(currentRunCommandProvider);
    final ready = ref.watch(runtimeControllerProvider.select((s) => s.usable));
    final active = ref.watch(
      documentControllerProvider.select((d) => d.activePath),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CfSpacing.lg,
            CfSpacing.md,
            CfSpacing.lg,
            CfSpacing.sm,
          ),
          child: Text(
            'RUN',
            style: textTheme.labelSmall?.copyWith(
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
          child: Wrap(
            spacing: CfSpacing.sm,
            runSpacing: CfSpacing.sm,
            children: [
              CfButton(
                key: const ValueKey('run_current_file'),
                label: current == null
                    ? 'Run current file'
                    : 'Run ${current.title}',
                icon: CfIcons.playArrow,
                onPressed: ready && current != null && !run.starting
                    ? () {
                        unawaited(controller.runFile(active!));
                        onRunStarted?.call();
                      }
                    : null,
              ),
              CfButton(
                key: const ValueKey('run_project'),
                label: 'Run project…',
                variant: CfButtonVariant.tonal,
                onPressed: ready && !run.starting
                    ? () => unawaited(_runProject(context, ref))
                    : null,
              ),
            ],
          ),
        ),
        if (!ready)
          const Padding(
            padding: EdgeInsets.fromLTRB(
              CfSpacing.lg,
              CfSpacing.sm,
              CfSpacing.lg,
              0,
            ),
            child: CfBanner(
              key: ValueKey('run_runtime_not_ready'),
              message: 'Run starts once the Linux runtime is ready.',
            ),
          ),
        const SizedBox(height: CfSpacing.sm),
        Expanded(
          child: run.runs.isEmpty
              ? const CfEmptyState(
                  key: ValueKey('run_empty'),
                  icon: CfIcons.playArrow,
                  title: 'Nothing has run yet',
                  message:
                      'Run the open file, or a script of the project, in the '
                      'Linux runtime. Its output shows in a terminal.',
                  phaseNote: 'Debugging arrives in Phase 9',
                )
              : ListView.builder(
                  key: const ValueKey('run_list'),
                  itemCount: run.runs.length,
                  itemBuilder: (context, index) =>
                      _RunRow(run: run.runs[index], onShown: onRunStarted),
                ),
        ),
      ],
    );
  }

  Future<void> _runProject(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(runControllerProvider.notifier);
    final runs = await controller.projectRuns();
    if (!context.mounted) {
      return;
    }
    final choice = await pickProjectRun(context, runs);
    if (choice == null) {
      return;
    }
    onRunStarted?.call();
    await controller.runCommand(choice);
  }
}

/// What Run Current File runs for the active document, or null when there
/// is none or Run cannot run it.
final currentRunCommandProvider = Provider<RunCommand?>((ref) {
  final active = ref.watch(
    documentControllerProvider.select((d) => d.activePath),
  );
  if (active == null) {
    return null;
  }
  final text = ref.watch(
    documentControllerProvider.select((d) => d.documents[active]?.savedText),
  );
  return runCommandForFile(
    active,
    firstLine: text == null ? null : firstLineOf(text),
  );
});

/// Asks which of [runs] to run; null when none is picked.
Future<RunCommand?> pickProjectRun(
  BuildContext context,
  List<RunCommand> runs,
) {
  return showDialog<RunCommand>(
    context: context,
    builder: (dialogContext) => CfAlertDialog(
      key: const ValueKey('run_project_dialog'),
      title: const Text('Run project'),
      content: runs.isEmpty
          ? const Text(
              'Nothing to run here: the project has no package.json scripts '
              'and none of the usual entry files (main.js, index.js, '
              'main.py and so on).',
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final run in runs)
                  ListTile(
                    key: ValueKey('run_choice:${run.title}'),
                    dense: true,
                    leading: const Icon(CfIcons.playArrow, size: 18),
                    title: Text(run.title),
                    subtitle: Text(
                      run.commandLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(dialogContext).pop(run),
                  ),
              ],
            ),
      actions: [
        CfButton(
          key: const ValueKey('run_project_cancel'),
          label: 'Cancel',
          variant: CfButtonVariant.ghost,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    ),
  );
}

/// One run: its chip, what ran, and what can be done with it.
class _RunRow extends ConsumerWidget {
  const _RunRow({required this.run, this.onShown});

  final RunRecord run;
  final VoidCallback? onShown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final controller = ref.read(runControllerProvider.notifier);
    final color = runStatusColor(colors, run);
    return Padding(
      key: ValueKey('run_row:${run.sessionId}'),
      padding: const EdgeInsets.only(left: CfSpacing.lg, right: CfSpacing.xs),
      child: Row(
        children: [
          CfStatusChip(
            key: ValueKey('run_status:${run.sessionId}'),
            label: run.status,
            color: color,
          ),
          const SizedBox(width: CfSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  run.command.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
                Text(
                  run.command.commandLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (run.running)
            CfIconButton(
              key: ValueKey('run_stop:${run.sessionId}'),
              icon: CfIcons.stop,
              tooltip: 'Stop',
              onPressed: () => unawaited(controller.stop(run.sessionId)),
            )
          else
            CfIconButton(
              key: ValueKey('run_again:${run.sessionId}'),
              icon: CfIcons.replay,
              tooltip: 'Run again',
              onPressed: () {
                unawaited(controller.rerun(run));
                onShown?.call();
              },
            ),
          if (!run.closed)
            CfIconButton(
              key: ValueKey('run_show:${run.sessionId}'),
              icon: CfIcons.terminal,
              tooltip: 'Show its terminal',
              onPressed: () {
                ref
                    .read(terminalControllerProvider.notifier)
                    .activate(run.sessionId);
                final shell = ref.read(shellControllerProvider);
                if (shell.terminalStop == TerminalStop.closed) {
                  ref
                      .read(shellControllerProvider.notifier)
                      .setTerminalStop(TerminalStop.half);
                }
                onShown?.call();
              },
            ),
        ],
      ),
    );
  }
}

/// A run's chip colour: the accent while it runs, success for exit 0,
/// danger for another code, warning for a signal.
Color runStatusColor(CfColors colors, RunRecord run) {
  if (run.running) {
    return colors.accentEmber;
  }
  if (run.exitCode == 0) {
    return colors.success;
  }
  if (run.exitCode != null) {
    return colors.danger;
  }
  return colors.warning;
}
