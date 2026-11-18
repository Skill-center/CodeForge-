/// The find bar (Phase 2 W6): find and replace in the active document, over
/// the page's search session (application/editor/find_controller.dart). It
/// sits above the editor, and every control is a 48 dp touch target.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../application/editor/find_controller.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/icons.dart';

/// Narrower than this, the option toggles get a row of their own.
const double findBarWideWidth = 560;

class FindBar extends ConsumerStatefulWidget {
  const FindBar({super.key, required this.rows});

  /// The rows to show, from [rowsFor]: the find row first, then the replace
  /// row while it is open, then (when narrow) the option toggles.
  final int rows;

  /// The rows the bar shows at [width], given at most [maxRows].
  static int rowsFor({
    required double width,
    required bool replaceOpen,
    required int maxRows,
  }) {
    final wanted =
        1 + (replaceOpen ? 1 : 0) + (width < findBarWideWidth ? 1 : 0);
    return wanted < maxRows ? wanted : maxRows;
  }

  /// The bar's height with [rows] rows, its hairline included.
  static double heightFor(int rows) =>
      rows * CfSpacing.minTouchTarget + CfSpacing.hairline;

  @override
  ConsumerState<FindBar> createState() => _FindBarState();
}

class _FindBarState extends ConsumerState<FindBar> {
  // Made in initState, not lazily: a field first touched in dispose() would
  // read a provider while the bar is unmounting, which Riverpod refuses.
  late final TextEditingController _query;
  late final TextEditingController _replacement;
  final FocusNode _queryFocus = FocusNode(debugLabel: 'find query');
  final FocusNode _replacementFocus = FocusNode(debugLabel: 'find replace');

  @override
  void initState() {
    super.initState();
    final find = ref.read(findControllerProvider);
    _query = TextEditingController(text: find.query);
    _replacement = TextEditingController(text: find.replacement);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusQuery());
  }

  @override
  void dispose() {
    _query.dispose();
    _replacement.dispose();
    _queryFocus.dispose();
    _replacementFocus.dispose();
    super.dispose();
  }

  FindController get _controller => ref.read(findControllerProvider.notifier);

  /// Puts the keyboard in the query field with its text selected, so typing
  /// replaces it.
  void _focusQuery() {
    if (!mounted) {
      return;
    }
    _queryFocus.requestFocus();
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
  }

  /// Hands the keyboard back to the editor only when the bar had it.
  void _close() {
    final hadKeyboard = _queryFocus.hasFocus || _replacementFocus.hasFocus;
    unawaited(_controller.close(refocusEditor: hadKeyboard));
  }

  @override
  Widget build(BuildContext context) {
    final find = ref.watch(findControllerProvider);
    ref.listen(findControllerProvider, (previous, next) {
      if (next.query != _query.text) {
        _query.text = next.query;
      }
      if (next.focusRequests != previous?.focusRequests) {
        _focusQuery();
      }
    });
    final colors = CfColors.of(context);
    final controller = _controller;
    final canStep = find.valid && find.matches > 0;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true):
            controller.previous,
        const SingleActivator(LogicalKeyboardKey.f3): controller.next,
        const SingleActivator(LogicalKeyboardKey.f3, shift: true):
            controller.previous,
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= findBarWideWidth;
          final options = _Options(find: find, controller: controller);
          final rows = <Widget>[
            Row(
              children: [
                CfIconButton(
                  key: const ValueKey('find_toggle_replace'),
                  icon: find.replaceOpen
                      ? CfIcons.expandMore
                      : CfIcons.chevronRight,
                  tooltip: find.replaceOpen ? 'Hide replace' : 'Replace',
                  onPressed: controller.toggleReplace,
                ),
                Expanded(
                  child: CfCodeField(
                    key: const ValueKey('find_query'),
                    controller: _query,
                    focusNode: _queryFocus,
                    hint: 'Find',
                    summary: find.summary,
                    summaryKey: const ValueKey('find_count'),
                    problem: find.query.isNotEmpty && !find.valid,
                    textInputAction: TextInputAction.search,
                    onChanged: controller.setQuery,
                    onSubmitted: controller.next,
                  ),
                ),
                if (wide) options,
                CfIconButton(
                  key: const ValueKey('find_previous'),
                  icon: CfIcons.keyboardArrowUp,
                  tooltip: 'Previous match',
                  onPressed: canStep ? controller.previous : null,
                ),
                CfIconButton(
                  key: const ValueKey('find_next'),
                  icon: CfIcons.keyboardArrowDown,
                  tooltip: 'Next match',
                  onPressed: canStep ? controller.next : null,
                ),
                CfIconButton(
                  key: const ValueKey('find_close'),
                  icon: CfIcons.close,
                  tooltip: 'Close',
                  onPressed: _close,
                ),
              ],
            ),
            if (find.replaceOpen)
              Row(
                children: [
                  const SizedBox(width: CfSpacing.minTouchTarget),
                  Expanded(
                    child: CfCodeField(
                      key: const ValueKey('find_replacement'),
                      controller: _replacement,
                      focusNode: _replacementFocus,
                      hint: 'Replace',
                      textInputAction: TextInputAction.done,
                      onChanged: controller.setReplacement,
                      onSubmitted: controller.replaceOne,
                    ),
                  ),
                  CfIconButton(
                    key: const ValueKey('find_replace'),
                    icon: CfIcons.findReplace,
                    tooltip: 'Replace',
                    onPressed: canStep ? controller.replaceOne : null,
                  ),
                  CfIconButton(
                    key: const ValueKey('find_replace_all'),
                    icon: CfIcons.doneAll,
                    tooltip: 'Replace all',
                    onPressed: canStep ? controller.replaceAll : null,
                  ),
                ],
              ),
            if (!wide)
              Row(
                children: [
                  const SizedBox(width: CfSpacing.minTouchTarget),
                  options,
                ],
              ),
          ];
          return DecoratedBox(
            key: const ValueKey('find_bar'),
            decoration: BoxDecoration(
              color: colors.surfacePanel,
              border: Border(
                bottom: BorderSide(
                  color: colors.borderSubtle,
                  width: CfSpacing.hairline,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.only(bottom: CfSpacing.hairline),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: rows.take(widget.rows).toList(),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Match case, whole word and regular expression.
class _Options extends StatelessWidget {
  const _Options({required this.find, required this.controller});

  final FindState find;
  final FindController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CfOptionToggle(
          key: const ValueKey('find_case'),
          label: 'Aa',
          tooltip: 'Match case',
          on: find.caseSensitive,
          onPressed: controller.toggleCaseSensitive,
        ),
        CfOptionToggle(
          key: const ValueKey('find_word'),
          label: 'ab',
          underline: true,
          tooltip: 'Whole word',
          on: find.wholeWord,
          onPressed: controller.toggleWholeWord,
        ),
        CfOptionToggle(
          key: const ValueKey('find_regex'),
          label: '.*',
          tooltip: 'Regular expression',
          on: find.regexp,
          onPressed: controller.toggleRegexp,
        ),
      ],
    );
  }
}
