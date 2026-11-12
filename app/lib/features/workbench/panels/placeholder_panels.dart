/// Honest placeholder panels for later phases: search, git, extensions,
/// run. Each states exactly what it will become and when, in ROADMAP's
/// phases (checked at Phase 3's exit: search across files moved to Phase 4
/// by the owner's decision of 2026-11-11).
library;

import 'package:flutter/material.dart';

import '../../../design_system/components/feedback.dart';
import '../../../design_system/tokens/icons.dart';

class SearchPanel extends StatelessWidget {
  const SearchPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const CfEmptyState(
      icon: CfIcons.search,
      title: 'Workspace search',
      message:
          'Full-text search across your project, with results grouped by '
          'file. To open a file by name, use Go to File… in the command '
          'palette (Ctrl+P).',
      phaseNote: 'Arrives in Phase 4',
    );
  }
}

class GitPanel extends StatelessWidget {
  const GitPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const CfEmptyState(
      icon: CfIcons.commit,
      title: 'Source control',
      message:
          'Stage, commit, branch and review diffs — powered by the bundled '
          'Linux runtime.',
      phaseNote: 'Arrives in Phase 7',
    );
  }
}

class ExtensionsPanel extends StatelessWidget {
  const ExtensionsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const CfEmptyState(
      icon: CfIcons.extension,
      title: 'Extensions',
      message:
          'Language packs and tools from a curated, Play-compliant catalog. '
          'No arbitrary code downloads.',
      phaseNote: 'Arrives in Phase 8',
    );
  }
}

class RunPanel extends StatelessWidget {
  const RunPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const CfEmptyState(
      icon: CfIcons.playArrow,
      title: 'Run & debug',
      message:
          'Run Python, Node.js and shell tasks in the sealed runtime with '
          'live output.',
      phaseNote: 'Running arrives in Phase 5, debugging in Phase 9',
    );
  }
}
