/// Honest placeholder panels for later phases: search, git, extensions,
/// run. Each states exactly what it will become and when.
library;

import 'package:flutter/material.dart';

import '../../../design_system/components/feedback.dart';

class SearchPanel extends StatelessWidget {
  const SearchPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const CfEmptyState(
      icon: Icons.search,
      title: 'Workspace search',
      message:
          'Full-text and filename search across your project, with results '
          'grouped by file.',
      phaseNote: 'Arrives in Phase 3',
    );
  }
}

class GitPanel extends StatelessWidget {
  const GitPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const CfEmptyState(
      icon: Icons.commit,
      title: 'Source control',
      message:
          'Stage, commit, branch and review diffs — powered by the bundled '
          'Linux runtime.',
      phaseNote: 'Arrives in Phase 6',
    );
  }
}

class ExtensionsPanel extends StatelessWidget {
  const ExtensionsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const CfEmptyState(
      icon: Icons.extension_outlined,
      title: 'Extensions',
      message:
          'Language packs and tools from a curated, Play-compliant catalog. '
          'No arbitrary code downloads.',
      phaseNote: 'Arrives in Phase 7',
    );
  }
}

class RunPanel extends StatelessWidget {
  const RunPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const CfEmptyState(
      icon: Icons.play_arrow_outlined,
      title: 'Run & debug',
      message:
          'Run Python, Node.js and shell tasks in the sealed runtime with '
          'live output.',
      phaseNote: 'Arrives in Phases 4–5',
    );
  }
}
