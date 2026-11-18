/// The Search panel (Phase 4 W6): search across the open workspace's files.
/// A query with match case, whole word and regular expression, as in the
/// find bar; files to include and to exclude, as globs; results grouped by
/// file as they come; a tap opens the file with the cursor at the match.
/// The search runs on Enter or the search button, and again when a switch
/// changes after one ran (application/search/search_controller.dart).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../application/documents/document_controller.dart';
import '../../../application/editor/editor_providers.dart';
import '../../../application/keyboard_state.dart';
import '../../../application/search/search_controller.dart';
import '../../../core/errors/failure.dart';
import '../../../core/files/workspace_path.dart';
import '../../../core/search/search_models.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/icons.dart';
import '../../../design_system/tokens/typography.dart';
import '../file_actions.dart';

class SearchPanel extends ConsumerStatefulWidget {
  const SearchPanel({super.key, this.onFileOpened});

  /// Runs after a result opened (the phone's sheet closes).
  final VoidCallback? onFileOpened;

  @override
  ConsumerState<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends ConsumerState<SearchPanel> {
  late final TextEditingController _query;
  late final TextEditingController _includes;
  late final TextEditingController _excludes;
  final FocusNode _queryFocus = FocusNode(debugLabel: 'search query');
  final FocusNode _includesFocus = FocusNode(debugLabel: 'search includes');
  final FocusNode _excludesFocus = FocusNode(debugLabel: 'search excludes');
  late bool _caseSensitive;
  late bool _regex;
  late bool _wholeWord;
  late bool _filtersOpen;

  @override
  void initState() {
    super.initState();
    // The panel comes and goes with the activity; the last query stays.
    final last = ref.read(searchControllerProvider).query;
    _query = TextEditingController(text: last.text);
    _includes = TextEditingController(text: last.includes.join(', '));
    _excludes = TextEditingController(text: last.excludes.join(', '));
    _caseSensitive = last.caseSensitive;
    _regex = last.regex;
    _wholeWord = last.wholeWord;
    _filtersOpen = last.includes.isNotEmpty || last.excludes.isNotEmpty;
  }

  @override
  void dispose() {
    _query.dispose();
    _includes.dispose();
    _excludes.dispose();
    _queryFocus.dispose();
    _includesFocus.dispose();
    _excludesFocus.dispose();
    super.dispose();
  }

  SearchQuery _current() => SearchQuery(
    text: _query.text,
    caseSensitive: _caseSensitive,
    regex: _regex,
    wholeWord: _wholeWord,
    includes: SearchQuery.globsOf(_includes.text),
    excludes: SearchQuery.globsOf(_excludes.text),
  );

  void _submit() {
    ref.read(searchControllerProvider.notifier).search(_current());
  }

  /// A switch changed: the results follow it once a search has run.
  void _switched(void Function() change) {
    setState(change);
    final shown = ref.read(searchControllerProvider);
    if (shown.phase != SearchPhase.idle && _query.text.isNotEmpty) {
      _submit();
    }
  }

  Future<void> _open(String path, SearchLine line) async {
    final opened = await ref
        .read(documentControllerProvider.notifier)
        .open(path);
    if (!mounted) {
      return;
    }
    if (opened case Err<void>(:final failure)) {
      showFileMessage(context, failure.message);
      return;
    }
    // Read before the sheet closes: on a phone the panel goes with it.
    final host = ref.read(editorHostProvider);
    // With a hardware keyboard the editor takes the keys at once; without
    // one, focusing would raise the soft keyboard over the result.
    final keyboard = ref.read(hardwareKeyboardProvider);
    widget.onFileOpened?.call();
    final moved = await host.gotoLine(line.line, column: line.column);
    if (moved.isOk && keyboard) {
      await host.exec('focus');
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final search = ref.watch(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CfSpacing.lg,
            CfSpacing.md,
            CfSpacing.sm,
            CfSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'SEARCH',
                  style: textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              CfIconButton(
                key: const ValueKey('search_clear'),
                icon: CfIcons.playlistRemove,
                tooltip: 'Clear results',
                size: 16,
                onPressed: search.phase == SearchPhase.idle
                    ? null
                    : () {
                        _query.clear();
                        controller.clear();
                      },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CfSpacing.sm),
          child: CfCodeField(
            key: const ValueKey('search_query'),
            controller: _query,
            focusNode: _queryFocus,
            hint: 'Search',
            textInputAction: TextInputAction.search,
            onChanged: (_) {},
            onSubmitted: _submit,
            keepKeyboard: false,
            problem: search.summary?.problem == SearchProblem.badQuery,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CfSpacing.sm),
          child: Row(
            children: [
              CfOptionToggle(
                key: const ValueKey('search_case'),
                label: 'Aa',
                tooltip: 'Match case',
                on: _caseSensitive,
                onPressed: () =>
                    _switched(() => _caseSensitive = !_caseSensitive),
              ),
              CfOptionToggle(
                key: const ValueKey('search_word'),
                label: 'ab',
                underline: true,
                tooltip: 'Whole word',
                on: _wholeWord,
                onPressed: () => _switched(() => _wholeWord = !_wholeWord),
              ),
              CfOptionToggle(
                key: const ValueKey('search_regex'),
                label: '.*',
                tooltip: 'Regular expression',
                on: _regex,
                onPressed: () => _switched(() => _regex = !_regex),
              ),
              const Spacer(),
              CfIconButton(
                key: const ValueKey('search_filters'),
                icon: CfIcons.moreHoriz,
                tooltip: _filtersOpen
                    ? 'Hide files to include and exclude'
                    : 'Files to include and exclude',
                selected: _filtersOpen,
                onPressed: () => setState(() => _filtersOpen = !_filtersOpen),
              ),
              CfIconButton(
                key: const ValueKey('search_go'),
                icon: CfIcons.search,
                tooltip: 'Search',
                onPressed: _submit,
              ),
            ],
          ),
        ),
        if (_filtersOpen) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CfSpacing.sm),
            child: CfCodeField(
              key: const ValueKey('search_includes'),
              controller: _includes,
              focusNode: _includesFocus,
              hint: 'Files to include (src, *.js)',
              textInputAction: TextInputAction.search,
              onChanged: (_) {},
              onSubmitted: _submit,
              keepKeyboard: false,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CfSpacing.sm),
            child: CfCodeField(
              key: const ValueKey('search_excludes'),
              controller: _excludes,
              focusNode: _excludesFocus,
              hint: 'Files to exclude (dist, *.min.js)',
              textInputAction: TextInputAction.search,
              onChanged: (_) {},
              onSubmitted: _submit,
              keepKeyboard: false,
            ),
          ),
        ],
        _StatusLine(search: search, onStop: controller.stop),
        Expanded(
          child: search.phase == SearchPhase.idle
              ? const _Hint()
              : _Results(
                  search: search,
                  onToggle: controller.toggleCollapsed,
                  onOpen: (path, line) => unawaited(_open(path, line)),
                ),
        ),
      ],
    );
  }
}

/// What the search found so far, or why it stopped.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.search, required this.onStop});

  final SearchState search;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final (text, problem) = searchStatus(search);
    if (text.isEmpty) {
      return const SizedBox(height: CfSpacing.sm);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CfSpacing.lg,
        CfSpacing.xs,
        CfSpacing.sm,
        CfSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              key: const ValueKey('search_status'),
              style: CfTypography.status(
                colors,
              ).copyWith(color: problem ? colors.danger : colors.textSecondary),
            ),
          ),
          if (search.phase == SearchPhase.running)
            CfIconButton(
              key: const ValueKey('search_stop'),
              icon: CfIcons.close,
              tooltip: 'Stop the search',
              size: 18,
              onPressed: () => unawaited(onStop()),
            ),
        ],
      ),
    );
  }
}

/// The status line's text for [search], and whether it reports a problem.
(String, bool) searchStatus(SearchState search) {
  final found =
      '${_count(search.lines, 'result')} in '
      '${_count(search.files.length, 'file')}';
  switch (search.phase) {
    case SearchPhase.idle:
      return ('', false);
    case SearchPhase.running:
      return (search.lines == 0 ? 'Searching…' : 'Searching… $found', false);
    case SearchPhase.stopping:
      return ('Stopping… $found so far', false);
    case SearchPhase.finished:
      break;
  }
  final summary = search.summary;
  if (summary == null) {
    return (found, false);
  }
  final left = summary.skipped == 0
      ? ''
      : ' · ${_count(summary.skipped, 'file')} left out (binary, over 10 MiB '
            'or not UTF-8)';
  switch (summary.outcome) {
    case SearchOutcome.done:
      return (
        search.lines == 0
            ? switch (summary.filesSearched) {
                null => 'No results$left',
                final int searched =>
                  'No results in ${_count(searched, 'file')}$left',
              }
            : '$found$left',
        false,
      );
    case SearchOutcome.limit:
      return (
        '$found: stopped at the limit. Narrow the search to see the rest.',
        false,
      );
    case SearchOutcome.cancelled:
      return ('Stopped: $found so far', false);
    case SearchOutcome.failed:
      return (_problemText(summary), true);
  }
}

String _problemText(SearchSummary summary) => switch (summary.problem) {
  SearchProblem.badQuery => summary.detail ?? 'This search cannot run.',
  SearchProblem.notFound =>
    'The folder is gone. Open it again from Home if it moved.',
  SearchProblem.accessLost =>
    'CodeForge lost its access to this folder. Open it again from Home.',
  SearchProblem.timedOut => 'The search took too long, and was stopped.',
  _ => 'The search failed: ${summary.detail ?? 'no reason given'}',
};

String _count(int n, String one, [String? many]) =>
    '${_thousands(n)} ${n == 1 ? one : many ?? '${one}s'}';

String _thousands(int n) {
  final digits = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      out.write(',');
    }
    out.write(digits[i]);
  }
  return out.toString();
}

/// Before any search.
class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(CfSpacing.lg),
      child: Text(
        'Search the text of every file in this workspace. Results are '
        'grouped by file: tap one to open it at its line. To open a file by '
        'name, use Go to File… in the command palette (Ctrl+P).',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

/// One row of the results: a file, or one of its lines.
final class _Row {
  const _Row.file(this.file) : line = null;
  const _Row.line(this.file, SearchLine this.line);

  final SearchFileResult file;
  final SearchLine? line;
}

class _Results extends StatelessWidget {
  const _Results({
    required this.search,
    required this.onToggle,
    required this.onOpen,
  });

  final SearchState search;
  final void Function(String path) onToggle;
  final void Function(String path, SearchLine line) onOpen;

  @override
  Widget build(BuildContext context) {
    final rows = <_Row>[];
    for (final file in search.files) {
      rows.add(_Row.file(file));
      if (!search.collapsed.contains(file.path)) {
        for (final line in file.lines) {
          rows.add(_Row.line(file, line));
        }
      }
    }
    return ListView.builder(
      key: const ValueKey('search_results'),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final line = row.line;
        if (line == null) {
          return _FileRow(
            file: row.file,
            collapsed: search.collapsed.contains(row.file.path),
            onTap: () => onToggle(row.file.path),
          );
        }
        return _LineRow(
          path: row.file.path,
          line: line,
          onTap: () => onOpen(row.file.path, line),
        );
      },
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.collapsed,
    required this.onTap,
  });

  final SearchFileResult file;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final folder = pathParent(file.path);
    return Semantics(
      container: true,
      button: true,
      expanded: !collapsed,
      label: '${file.path}, ${_count(file.matches, 'match', 'matches')}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('search_file_${file.path}'),
        onTap: onTap,
        child: SizedBox(
          height: CfSpacing.minTouchTarget,
          child: Row(
            children: [
              const SizedBox(width: CfSpacing.xs),
              Icon(
                collapsed ? CfIcons.chevronRight : CfIcons.expandMore,
                size: 18,
                color: colors.textSecondary,
              ),
              const SizedBox(width: CfSpacing.xs),
              Flexible(
                child: Text(
                  pathBaseName(file.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (folder.isNotEmpty) ...[
                const SizedBox(width: CfSpacing.sm),
                Flexible(
                  child: Text(
                    folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: CfSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: CfSpacing.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceRaised,
                  borderRadius: BorderRadius.circular(CfRadius.sm),
                ),
                child: Text(
                  _thousands(file.matches),
                  style: CfTypography.status(colors),
                ),
              ),
              const SizedBox(width: CfSpacing.md),
            ],
          ),
        ),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.path, required this.line, required this.onTap});

  final String path;
  final SearchLine line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final code = CfTypography.code(colors, fontSize: 13);
    final (spans, plain) = previewSpans(line, code, colors);
    return Semantics(
      container: true,
      button: true,
      label: 'Line ${line.line}: $plain',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('search_line_$path:${line.line}'),
        onTap: onTap,
        child: SizedBox(
          height: CfSpacing.minTouchTarget,
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  '${line.line}',
                  textAlign: TextAlign.right,
                  style: code.copyWith(color: colors.textSecondary),
                ),
              ),
              const SizedBox(width: CfSpacing.md),
              Expanded(
                child: Text.rich(
                  TextSpan(children: spans),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
              const SizedBox(width: CfSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }
}

/// [line]'s preview as spans with its matches marked, and as plain text.
/// Leading blanks are dropped, as long as no match starts in them; a line
/// cut before or after its preview shows an ellipsis there.
(List<TextSpan>, String) previewSpans(
  SearchLine line,
  TextStyle style,
  CfColors colors,
) {
  final preview = line.preview;
  final first = line.ranges.isEmpty ? preview.length : line.ranges.first;
  var start = 0;
  while (start < preview.length &&
      start < first &&
      (preview[start] == ' ' || preview[start] == '\t')) {
    start++;
  }
  final mark = style.copyWith(
    color: colors.accentEmber,
    backgroundColor: colors.accentEmberSoft,
    fontWeight: FontWeight.w600,
  );
  final spans = <TextSpan>[];
  final plain = StringBuffer();
  void add(String text, TextStyle textStyle) {
    if (text.isEmpty) {
      return;
    }
    spans.add(TextSpan(text: text, style: textStyle));
    plain.write(text);
  }

  if (line.previewStart > 0) {
    add('…', style);
  }
  var at = start;
  for (var i = 0; i + 1 < line.ranges.length; i += 2) {
    final from = line.ranges[i].clamp(at, preview.length);
    final to = line.ranges[i + 1].clamp(from, preview.length);
    add(preview.substring(at, from), style);
    add(preview.substring(from, to), mark);
    at = to;
  }
  add(preview.substring(at), style);
  if (line.cutEnd) {
    add('…', style);
  }
  return (spans, plain.toString());
}
