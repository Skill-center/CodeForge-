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
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/icons.dart';
import '../../../design_system/tokens/typography.dart';

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
                  child: _BarField(
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
                    child: _BarField(
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
        _OptionToggle(
          key: const ValueKey('find_case'),
          label: 'Aa',
          tooltip: 'Match case',
          on: find.caseSensitive,
          onPressed: controller.toggleCaseSensitive,
        ),
        _OptionToggle(
          key: const ValueKey('find_word'),
          label: 'ab',
          underline: true,
          tooltip: 'Whole word',
          on: find.wholeWord,
          onPressed: controller.toggleWholeWord,
        ),
        _OptionToggle(
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

/// A two-state option drawn as text, as desktop editors show these.
class _OptionToggle extends StatelessWidget {
  const _OptionToggle({
    super.key,
    required this.label,
    required this.tooltip,
    required this.on,
    required this.onPressed,
    this.underline = false,
  });

  final String label;
  final String tooltip;
  final bool on;
  final VoidCallback onPressed;
  final bool underline;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    // One node for TalkBack: a toggle with its state, tappable.
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      label: tooltip,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: on ? colors.accentEmberSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(CfRadius.sm),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(CfRadius.sm),
            child: SizedBox.square(
              dimension: CfSpacing.minTouchTarget,
              child: Center(
                child: Text(
                  label,
                  style: CfTypography.code(colors).copyWith(
                    color: on ? colors.accentEmber : colors.textSecondary,
                    decoration: underline ? TextDecoration.underline : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A one-line field of the bar, in the code font, with an optional count
/// at its end.
class _BarField extends StatelessWidget {
  const _BarField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.textInputAction,
    required this.onChanged,
    required this.onSubmitted,
    this.summary = '',
    this.summaryKey,
    this.problem = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final TextInputAction textInputAction;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final String summary;
  final Key? summaryKey;
  final bool problem;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    // The field fills its 48 dp row, so all of the row takes taps (G7); the
    // box drawn behind it is inset, so stacked rows do not touch.
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: CfSpacing.xs),
            child: ListenableBuilder(
              listenable: focusNode,
              builder: (context, _) => DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceSunken,
                  borderRadius: BorderRadius.circular(CfRadius.sm),
                  border: Border.all(
                    color: problem
                        ? colors.danger
                        : focusNode.hasFocus
                        ? colors.accentEmber
                        : colors.borderSubtle,
                  ),
                ),
              ),
            ),
          ),
        ),
        TextField(
          controller: controller,
          focusNode: focusNode,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: textInputAction,
          textAlignVertical: TextAlignVertical.center,
          style: CfTypography.code(colors),
          decoration: InputDecoration(
            isDense: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            hintText: hint,
            constraints: const BoxConstraints(
              minHeight: CfSpacing.minTouchTarget,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: CfSpacing.md,
              vertical: CfSpacing.sm,
            ),
            suffixIcon: summary.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: CfSpacing.md),
                    child: Text(
                      summary,
                      key: summaryKey,
                      style: CfTypography.status(colors).copyWith(
                        color: problem ? colors.danger : colors.textSecondary,
                      ),
                    ),
                  ),
            suffixIconConstraints: const BoxConstraints(),
          ),
          onChanged: onChanged,
          onSubmitted: (_) => onSubmitted(),
          // Keep the keyboard: Enter steps to the next match, it does not end
          // the search.
          onEditingComplete: () {},
        ),
      ],
    );
  }
}
