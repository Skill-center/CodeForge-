/// A definition in a language server's own files, read-only (Phase 6 W5,
/// PHASE_6_PLAN W5): Python's stubs, TypeScript's `lib.d.ts`, a package in
/// the runtime. The file is shown with its line numbers in the editor's
/// font, at the definition, which is marked. Nothing in it can change.
library;

import 'package:material_ui/material_ui.dart';

import '../../application/lsp/lsp_features.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';
import '../../design_system/tokens/typography.dart';

/// Shows [view] read-only.
Future<void> showLibraryFile(BuildContext context, LibraryView view) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => LibraryFileSheet(view: view),
  );
}

class LibraryFileSheet extends StatefulWidget {
  const LibraryFileSheet({super.key, required this.view});

  final LibraryView view;

  /// Each line's height: fixed, so a file of many thousand lines scrolls
  /// straight to the definition.
  static const double lineHeight = 20;

  @override
  State<LibraryFileSheet> createState() => _LibraryFileSheetState();
}

class _LibraryFileSheetState extends State<LibraryFileSheet> {
  late final List<String> _lines = widget.view.text.split('\n');
  late final ScrollController _scroll = ScrollController(
    // A few lines above the definition, so it is not at the very top.
    initialScrollOffset:
        (widget.view.line - 3).clamp(0, _lines.length) *
        LibraryFileSheet.lineHeight,
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final view = widget.view;
    final digits = '${_lines.length}'.length;
    final code = CfTypography.code(colors, fontSize: 13).copyWith(height: 1.2);
    return SafeArea(
      key: const ValueKey('library_file_sheet'),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CfSpacing.lg,
                0,
                CfSpacing.lg,
                CfSpacing.sm,
              ),
              child: Row(
                children: [
                  const Icon(CfIcons.visibility, size: 18),
                  const SizedBox(width: CfSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${view.name}, line ${view.line + 1}',
                          style: textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${view.where} · read-only',
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('library_file_close'),
                    tooltip: 'Close',
                    icon: const Icon(CfIcons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.borderSubtle),
            Expanded(
              child: ColoredBox(
                color: colors.surfaceSunken,
                child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: _widthFor(digits),
                      child: ListView.builder(
                        controller: _scroll,
                        itemExtent: LibraryFileSheet.lineHeight,
                        itemCount: _lines.length,
                        itemBuilder: (context, index) {
                          final target = index == view.line;
                          return ColoredBox(
                            key: target
                                ? const ValueKey('library_file_target')
                                : null,
                            color: target
                                ? colors.accentEmberSoft
                                : Colors.transparent,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: digits * 9.0 + CfSpacing.lg,
                                  child: Text(
                                    '${index + 1}',
                                    textAlign: TextAlign.right,
                                    style: code.copyWith(
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: CfSpacing.md),
                                Text(
                                  _lines[index],
                                  softWrap: false,
                                  style: code.copyWith(
                                    color: colors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Wide enough for the longest line, at the font's advance; at least the
  /// screen's width.
  double _widthFor(int digits) {
    var longest = 0;
    for (final line in _lines) {
      if (line.length > longest) {
        longest = line.length;
      }
    }
    final width = digits * 9.0 + CfSpacing.lg + CfSpacing.md + longest * 8.0 + 24;
    final screen = MediaQuery.sizeOf(context).width;
    return width < screen ? screen : width.clamp(screen, 20000.0);
  }
}
