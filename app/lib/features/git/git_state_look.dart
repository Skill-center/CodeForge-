/// What Git's states look like (Phase 7 W4): the colour the Source
/// control panel and the explorer give a file, so the same change has the
/// same colour wherever it shows.
///
/// Red for what is gone or conflicted, amber for a change, blue for a
/// move, green for what is new — each of them a CfColors token, so the
/// contrast test (test/design_system/contrast_test.dart) covers them.
library;

import 'package:material_ui/material_ui.dart';

import '../../application/git/git_file_states.dart';
import '../../design_system/tokens/colors.dart';

Color gitStateColor(GitFileState state, CfColors colors) => switch (state) {
  GitFileState.conflicted || GitFileState.deleted => colors.danger,
  GitFileState.modified => colors.warning,
  GitFileState.renamed => colors.info,
  GitFileState.added || GitFileState.untracked => colors.success,
};
