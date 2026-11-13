/// File tree rows for the explorer: the workspace folder's real files from
/// Phase 2 W4 (features/workbench/panels/explorer_panel.dart).
library;

import 'package:material_ui/material_ui.dart';

import '../tokens/colors.dart';
import '../tokens/file_glyphs.dart';
import '../tokens/geometry.dart';
import '../tokens/icons.dart';

/// One file or folder shown by a [CfTreeRow].
final class CfFileNode {
  const CfFileNode({
    required this.name,
    required this.path,
    required this.isFile,
    this.children = const [],
    this.hidden = false,
  });

  final String name;
  final String path;
  final bool isFile;
  final List<CfFileNode> children;
  final bool hidden;
}

/// Indented tree row: chevron, icon, name. Real expand/collapse. Since
/// Phase 3 W4 a long-press opens the row's menu, and [trailing] (the
/// selected row's ⋯ button) sits at its end.
class CfTreeRow extends StatelessWidget {
  const CfTreeRow({
    super.key,
    required this.node,
    required this.depth,
    required this.expanded,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.trailing,
  });

  final CfFileNode node;
  final int depth;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final Widget? trailing;

  /// Folders draw Material Symbols; files draw their type's glyph.
  IconData get _icon {
    if (!node.isFile) {
      return expanded ? CfIcons.folderOpen : CfIcons.folder;
    }
    return CfFileGlyphs.forName(node.name);
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final fg = node.hidden ? colors.textDisabled : colors.textPrimary;
    return Material(
      color: selected ? colors.accentEmberSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          height: CfSpacing.minTouchTarget,
          padding: EdgeInsets.only(left: CfSpacing.sm + depth * 16.0),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: node.isFile
                    ? null
                    : Icon(
                        expanded ? CfIcons.expandMore : CfIcons.chevronRight,
                        size: 16,
                        color: colors.textSecondary,
                      ),
              ),
              Icon(_icon, size: 16, color: colors.textSecondary),
              const SizedBox(width: CfSpacing.sm),
              Expanded(
                child: Text(
                  node.name,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: fg, fontSize: 13),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
