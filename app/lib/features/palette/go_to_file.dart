/// Go to File (Phase 3 W4): finds a file in the workspace by fuzzy matching
/// its path (core/files/fuzzy_match.dart) over the workspace's index
/// (application/file_index.dart). Ctrl+P, or *Go to File…* in the command
/// palette. Hidden files follow the explorer's setting.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/file_index.dart';
import '../../application/settings_controller.dart';
import '../../core/files/fuzzy_match.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/file_glyphs.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';
import '../../design_system/tokens/typography.dart';

/// How many matches are listed.
const int goToFileResults = 100;

/// Shows Go to File; answers the path picked, or null.
Future<String?> showGoToFile(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) => const _GoToFileDialog(),
  );
}

/// [count] with thousands separators: 50000 → '50,000'.
String formatCount(int count) {
  final digits = count.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      out.write(',');
    }
    out.write(digits[i]);
  }
  return out.toString();
}

/// What the line under the results says about the index.
String goToFileStatus(FileIndexState index) {
  const skipped = '.git and node_modules are skipped.';
  final count = formatCount(index.files.length);
  return switch (index.status) {
    FileIndexStatus.idle ||
    FileIndexStatus.building => 'Finding files… $count so far',
    FileIndexStatus.failed =>
      'The files could not be listed. ${index.failure?.message ?? ''}'.trim(),
    FileIndexStatus.ready when index.truncated =>
      'Only the first ${formatCount(FileIndexController.maxEntries)} files '
          'are searched, so some can’t be found here. $skipped',
    FileIndexStatus.ready => '$count files. $skipped',
  };
}

class _GoToFileDialog extends ConsumerStatefulWidget {
  const _GoToFileDialog();

  @override
  ConsumerState<_GoToFileDialog> createState() => _GoToFileDialogState();
}

class _GoToFileDialogState extends ConsumerState<_GoToFileDialog> {
  final TextEditingController _query = TextEditingController();
  int _highlighted = 0;

  // Enter on a hardware keyboard and the soft keyboard's action both pick:
  // only the first may close the dialog.
  bool _picked = false;

  // The last search, so that typing on narrows its matches instead of
  // searching every file again.
  List<FuzzyTarget>? _searchedFiles;
  bool? _searchedHidden;
  String _searchedQuery = '';
  List<FuzzyTarget> _candidates = const [];
  List<PathMatch> _results = const [];

  @override
  void initState() {
    super.initState();
    // After the first frame: building changes the index's state at once,
    // which may not happen while the tree builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(fileIndexProvider.notifier).ensureBuilt();
      }
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// The matches for the current query among [files].
  List<PathMatch> _search(List<FuzzyTarget> files, bool showHidden) {
    final query = normalizeQuery(_query.text);
    if (identical(files, _searchedFiles) &&
        showHidden == _searchedHidden &&
        query == _searchedQuery) {
      return _results;
    }
    final narrowing =
        identical(files, _searchedFiles) &&
        showHidden == _searchedHidden &&
        query.startsWith(_searchedQuery);
    final pool = narrowing
        ? _candidates
        : [
            for (final file in files)
              if (showHidden || !file.hidden) file,
          ];
    _candidates = query.isEmpty
        ? pool
        : [
            for (final file in pool)
              if (fuzzyContains(query, file)) file,
          ];
    _searchedFiles = files;
    _searchedHidden = showHidden;
    _searchedQuery = query;
    _results = rankTargets(query, _candidates, limit: goToFileResults);
    if (_highlighted >= _results.length) {
      _highlighted = 0;
    }
    return _results;
  }

  void _pick(String path) {
    if (_picked) {
      return;
    }
    _picked = true;
    Navigator.of(context).pop(path);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_results.isEmpty) {
      return KeyEventResult.ignored;
    }
    final last = _results.length - 1;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlighted = (_highlighted + 1).clamp(0, last).toInt());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlighted = (_highlighted - 1).clamp(0, last).toInt());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _pick(_results[_highlighted].path);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final index = ref.watch(fileIndexProvider);
    final showHidden = ref.watch(
      settingsControllerProvider.select((s) => s.showHiddenFiles),
    );
    final results = _search(index.files, showHidden);
    // As the command palette: a smaller top inset while the soft keyboard
    // leaves little room.
    final room =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final topInset = (room * 0.1)
        .clamp(CfSpacing.sm, CfSpacing.xxl * 2)
        .toDouble();
    final building =
        index.status == FileIndexStatus.idle ||
        index.status == FileIndexStatus.building;
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: EdgeInsets.fromLTRB(
        CfSpacing.lg,
        topInset,
        CfSpacing.lg,
        CfSpacing.lg,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(CfSpacing.md),
              child: Focus(
                onKeyEvent: _onKey,
                child: TextField(
                  key: const ValueKey('go_to_file_input'),
                  controller: _query,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() => _highlighted = 0),
                  onSubmitted: (_) {
                    if (_results.isNotEmpty) {
                      _pick(_results[_highlighted].path);
                    }
                  },
                  decoration: const InputDecoration(
                    hintText: 'Type a file name…',
                    prefixIcon: Icon(CfIcons.search, size: 18),
                  ),
                ),
              ),
            ),
            Flexible(
              child: results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(CfSpacing.xl),
                      child: Text(
                        building
                            ? 'Looking for files…'
                            : index.files.isEmpty
                            ? 'No files in this workspace'
                            : 'No matching files',
                        key: const ValueKey('go_to_file_empty'),
                        style: textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (context, row) => _ResultRow(
                        match: results[row],
                        selected: row == _highlighted,
                        onTap: () => _pick(results[row].path),
                      ),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: CfSpacing.lg,
                vertical: CfSpacing.sm,
              ),
              child: Row(
                children: [
                  if (building) ...[
                    const SizedBox.square(
                      dimension: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                    const SizedBox(width: CfSpacing.sm),
                  ],
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        goToFileStatus(index),
                        key: const ValueKey('go_to_file_status'),
                        style: textTheme.labelSmall?.copyWith(
                          color: index.status == FileIndexStatus.failed
                              ? colors.danger
                              : colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One match: the file's glyph, its name and its folder, with the matched
/// characters in the accent colour.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.match,
    required this.selected,
    required this.onTap,
  });

  final PathMatch match;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final path = match.path;
    final nameStart = path.lastIndexOf('/') + 1;
    final name = path.substring(nameStart);
    final folder = nameStart == 0 ? '' : path.substring(0, nameStart - 1);
    final nameStyle = textTheme.bodyMedium ?? const TextStyle();
    final folderStyle = CfTypography.code(
      colors,
      fontSize: 11,
    ).copyWith(color: colors.textSecondary);
    return Semantics(
      button: true,
      selected: selected,
      label: folder.isEmpty ? name : '$name, in $folder',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? colors.accentEmberSoft : Colors.transparent,
        child: InkWell(
          key: ValueKey('go_to_file_$path'),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(
              minHeight: CfSpacing.minTouchTarget,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: CfSpacing.lg,
              vertical: CfSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  CfFileGlyphs.forName(name),
                  size: 16,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: CfSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        _highlight(
                          name,
                          nameStart,
                          match.positions,
                          nameStyle,
                          colors.accentEmber,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (folder.isNotEmpty)
                        Text.rich(
                          _highlight(
                            folder,
                            0,
                            match.positions,
                            folderStyle,
                            colors.accentEmber,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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

  /// [text], which starts at [offset] in the path, with the characters at
  /// [positions] (indices into the path) in [hit] and bold.
  static TextSpan _highlight(
    String text,
    int offset,
    List<int> positions,
    TextStyle base,
    Color hit,
  ) {
    final hits = {
      for (final position in positions)
        if (position >= offset && position < offset + text.length)
          position - offset,
    };
    if (hits.isEmpty) {
      return TextSpan(text: text, style: base);
    }
    final hitStyle = base.copyWith(color: hit, fontWeight: FontWeight.w700);
    final spans = <TextSpan>[];
    var start = 0;
    while (start < text.length) {
      final matched = hits.contains(start);
      var end = start + 1;
      while (end < text.length && hits.contains(end) == matched) {
        end++;
      }
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: matched ? hitStyle : base,
        ),
      );
      start = end;
    }
    return TextSpan(children: spans);
  }
}
