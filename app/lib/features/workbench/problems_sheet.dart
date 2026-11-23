/// The Problems sheet (Phase 6 W5, PHASE_6_PLAN W5): the open files'
/// diagnostics, as their servers found them, file by file; a tap goes to
/// the place.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/documents/document_controller.dart';
import '../../application/editor/editor_providers.dart';
import '../../application/lsp/lsp_features.dart';
import '../../core/errors/failure.dart';
import '../../core/lsp/lsp_models.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';
import 'file_actions.dart' show showFileMessage;

/// Shows the Problems sheet.
Future<void> showProblemsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => const ProblemsSheet(),
  );
}

/// What a problem's severity looks like.
({IconData icon, Color color, String label}) severityLook(
  LspSeverity severity,
  CfColors colors,
) => switch (severity) {
  LspSeverity.error => (
    icon: CfIcons.error,
    color: colors.danger,
    label: 'Error',
  ),
  LspSeverity.warning => (
    icon: CfIcons.warning,
    color: colors.warning,
    label: 'Warning',
  ),
  LspSeverity.information => (
    icon: CfIcons.info,
    color: colors.info,
    label: 'Information',
  ),
  LspSeverity.hint => (
    icon: CfIcons.info,
    color: colors.textSecondary,
    label: 'Hint',
  ),
};

/// "2 errors, 1 warning": the counts that are not zero.
String describeCounts(ProblemCounts counts) {
  String of(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
  final parts = [
    if (counts.errors > 0) of(counts.errors, 'error'),
    if (counts.warnings > 0) of(counts.warnings, 'warning'),
    if (counts.others > 0) of(counts.others, 'note'),
  ];
  return parts.isEmpty ? 'No problems' : parts.join(', ');
}

class ProblemsSheet extends ConsumerWidget {
  const ProblemsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problems = ref.watch(lspFeaturesProvider);
    final textTheme = Theme.of(context).textTheme;
    final colors = CfColors.of(context);
    final files = problems.files.entries.toList();
    final height = MediaQuery.sizeOf(context).height;
    return SafeArea(
      key: const ValueKey('problems_sheet'),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CfSpacing.lg,
                0,
                CfSpacing.lg,
                CfSpacing.sm,
              ),
              child: Semantics(
                header: true,
                child: Text(
                  files.isEmpty
                      ? 'Problems'
                      : 'Problems: ${describeCounts(problems.total)}',
                  style: textTheme.titleMedium,
                ),
              ),
            ),
            if (files.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  CfSpacing.lg,
                  CfSpacing.sm,
                  CfSpacing.lg,
                  CfSpacing.xl,
                ),
                child: Text(
                  key: const ValueKey('problems_empty'),
                  'No problems in the open files.',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final MapEntry(key: path, value: diagnostics) in files)
                      ..._fileRows(context, ref, path, diagnostics),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _fileRows(
    BuildContext context,
    WidgetRef ref,
    String path,
    List<LspDiagnostic> diagnostics,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final colors = CfColors.of(context);
    final name = path.split('/').last;
    final sorted = [...diagnostics]
      ..sort((a, b) {
        final line = a.range.start.line.compareTo(b.range.start.line);
        return line != 0
            ? line
            : a.range.start.character.compareTo(b.range.start.character);
      });
    return [
      Padding(
        key: ValueKey('problems_file_$path'),
        padding: const EdgeInsets.fromLTRB(
          CfSpacing.lg,
          CfSpacing.md,
          CfSpacing.lg,
          CfSpacing.xs,
        ),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: name, style: textTheme.titleSmall),
              TextSpan(
                text: name == path ? '' : '  $path',
                style: textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              TextSpan(
                text: '  ${describeCounts(ProblemCounts.of(diagnostics))}',
                style: textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      for (final (index, diagnostic) in sorted.indexed)
        _ProblemRow(
          key: ValueKey('problem_${path}_$index'),
          diagnostic: diagnostic,
          onTap: () => unawaited(_goTo(context, ref, path, diagnostic)),
        ),
    ];
  }

  Future<void> _goTo(
    BuildContext context,
    WidgetRef ref,
    String path,
    LspDiagnostic diagnostic,
  ) async {
    final navigator = Navigator.of(context);
    final host = ref.read(editorHostProvider);
    final opened = await ref
        .read(documentControllerProvider.notifier)
        .open(path);
    if (!context.mounted) {
      return;
    }
    if (opened case Err<void>(:final failure)) {
      showFileMessage(context, failure.message);
      return;
    }
    navigator.pop();
    final start = diagnostic.range.start;
    await host.gotoLine(start.line + 1, column: start.character + 1);
  }
}

class _ProblemRow extends StatelessWidget {
  const _ProblemRow({super.key, required this.diagnostic, required this.onTap});

  final LspDiagnostic diagnostic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final look = severityLook(diagnostic.severity, colors);
    final start = diagnostic.range.start;
    final source = diagnostic.source;
    final code = diagnostic.code;
    final where = [
      'Line ${start.line + 1}, column ${start.character + 1}',
      if (source != null) code == null ? source : '$source($code)',
    ].join(' · ');
    return Semantics(
      button: true,
      label: '${look.label}: ${diagnostic.message}. $where',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: CfSpacing.minTouchTarget,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: CfSpacing.lg,
              vertical: CfSpacing.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(look.icon, size: 18, color: look.color),
                ),
                const SizedBox(width: CfSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        diagnostic.message,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        where,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
