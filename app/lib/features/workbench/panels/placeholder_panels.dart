/// Honest placeholder panels for later phases: git and extensions. Each
/// states exactly what it will become and when, in ROADMAP's phases. Search
/// left this file when it arrived in Phase 4 W6 (search_panel.dart), Run
/// when it arrived in Phase 5 W4 (run_panel.dart).
library;

import 'package:material_ui/material_ui.dart';

import '../../../design_system/components/feedback.dart';
import '../../../design_system/tokens/icons.dart';

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
