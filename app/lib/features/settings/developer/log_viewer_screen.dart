/// Settings → Developer → Log viewer (debug and profile builds; Phase 3 W6,
/// a Phase 1 item the owner placed in W6): this session's log records, the
/// logger's ring buffer, newest first, narrowed by level and by tag. It
/// follows new records as they come, and copies what it shows.
///
/// The records are the logger's own, redacted before any sink or the ring
/// buffer saw them (docs/SECURITY.md §4). About → Recent logs keeps the
/// whole log, earlier sessions too, and saves it.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/logging/logger.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/icons.dart';
import '../../../design_system/tokens/typography.dart';

/// The records in [records] (oldest first, as the logger keeps them) at
/// [minimum] or above whose tag is one of [tags], or any tag when [tags]
/// is empty, newest first.
List<LogRecord> filterLogRecords(
  Iterable<LogRecord> records, {
  LogLevel minimum = LogLevel.debug,
  Set<String> tags = const {},
}) => [
  for (final record in records.toList().reversed)
    if (record.level.index >= minimum.index &&
        (tags.isEmpty || tags.contains(record.tag)))
      record,
];

/// The tags in [records], sorted.
List<String> logTagsOf(Iterable<LogRecord> records) =>
    {for (final record in records) record.tag}.toList()..sort();

/// What the level filter's segment for [level] says: that level and above.
String logLevelLabel(LogLevel level) => switch (level) {
  LogLevel.debug => 'All',
  LogLevel.info => 'Info',
  LogLevel.warn => 'Warn',
  LogLevel.error => 'Error',
};

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key, this.logger});

  /// Defaults to the app's logger.
  final CfLogger? logger;

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  /// The tag menu's "All tags": no tag is empty.
  static const String _allTags = '';

  late final CfLogger _logger = widget.logger ?? appLogger;
  LogLevel _minimum = LogLevel.debug;
  final Set<String> _tags = {};
  Timer? _redraw;

  @override
  void initState() {
    super.initState();
    _logger.addSink(_onRecord);
  }

  @override
  void dispose() {
    _logger.removeSink(_onRecord);
    _redraw?.cancel();
    super.dispose();
  }

  /// A record can come while the framework builds or lays out: the screen
  /// redraws once after it, for any number of records.
  void _onRecord(LogRecord record) {
    _redraw ??= Timer(Duration.zero, () {
      _redraw = null;
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _copy(List<LogRecord> shown) async {
    await Clipboard.setData(
      ClipboardData(text: shown.reversed.map((r) => r.render()).join('\n')),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied ${_entries(shown.length)}')),
      );
    }
  }

  void _toggleTag(String tag) {
    setState(() {
      if (tag == _allTags) {
        _tags.clear();
      } else if (!_tags.remove(tag)) {
        _tags.add(tag);
      }
    });
  }

  /// The tags to choose from: a menu with a 48 dp row for each.
  Widget _tagMenu(List<String> tags, TextTheme textTheme) {
    final chosen = (_tags.toList()..sort()).join(', ');
    return PopupMenuButton<String>(
      key: const ValueKey('log_viewer_tags'),
      tooltip: 'Show some tags only',
      onSelected: _toggleTag,
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          key: const ValueKey('log_tag_all'),
          value: _allTags,
          checked: _tags.isEmpty,
          child: const Text('All tags'),
        ),
        const PopupMenuDivider(),
        for (final tag in tags)
          CheckedPopupMenuItem<String>(
            key: ValueKey('log_tag_$tag'),
            value: tag,
            checked: _tags.contains(tag),
            child: Text(tag),
          ),
      ],
      child: SizedBox(
        height: CfSpacing.minTouchTarget,
        child: Row(
          children: [
            Flexible(
              child: Text(
                _tags.isEmpty ? 'Tags: all' : 'Tags: $chosen',
                key: const ValueKey('log_viewer_tags_label'),
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: CfSpacing.xs),
            const Icon(CfIcons.expandMore, size: 18),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final records = _logger.records;
    // A chosen tag whose records all left the ring buffer stays on the
    // menu, chosen.
    final tags = {...logTagsOf(records), ..._tags}.toList()..sort();
    final shown = filterLogRecords(records, minimum: _minimum, tags: _tags);
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log viewer'),
        actions: [
          CfIconButton(
            key: const ValueKey('log_viewer_copy'),
            icon: CfIcons.contentCopy,
            tooltip: 'Copy the entries shown',
            onPressed: shown.isEmpty ? null : () => _copy(shown),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              CfSpacing.lg,
              CfSpacing.sm,
              CfSpacing.lg,
              0,
            ),
            child: SegmentedButton<LogLevel>(
              key: const ValueKey('log_viewer_level'),
              segments: [
                for (final level in LogLevel.values)
                  ButtonSegment(
                    value: level,
                    label: Text(
                      logLevelLabel(level),
                      key: ValueKey('log_level_${level.name}'),
                    ),
                  ),
              ],
              selected: {_minimum},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  setState(() => _minimum = selection.first),
            ),
          ),
          if (tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
              child: _tagMenu(tags, textTheme),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: CfSpacing.lg,
              vertical: CfSpacing.xs,
            ),
            child: Text(
              'Showing ${shown.length} of ${_entries(records.length)}',
              key: const ValueKey('log_viewer_count'),
              style: textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(
                      records.isEmpty
                          ? 'No log entries yet'
                          : 'No entries at this level and tag',
                      key: const ValueKey('log_viewer_empty'),
                      style: textTheme.bodySmall,
                    ),
                  )
                : ListView.builder(
                    key: const ValueKey('log_viewer_list'),
                    padding: const EdgeInsets.fromLTRB(
                      CfSpacing.lg,
                      0,
                      CfSpacing.lg,
                      CfSpacing.lg,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, index) {
                      final record = shown[index];
                      final color = switch (record.level) {
                        LogLevel.error => colors.danger,
                        LogLevel.warn => colors.warning,
                        LogLevel.info => colors.textPrimary,
                        LogLevel.debug => colors.textSecondary,
                      };
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          record.render(),
                          style: CfTypography.code(
                            colors,
                            fontSize: 11,
                          ).copyWith(color: color),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

String _entries(int count) => count == 1 ? '1 entry' : '$count entries';
