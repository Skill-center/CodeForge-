/// Inputs shared by the workbench's bars and panels: the option toggles
/// (match case, whole word, regular expression) and the one-line code-font
/// field, first the find bar's (Phase 2 W6), shared with the Search panel
/// since Phase 4 W6.
library;

import 'package:material_ui/material_ui.dart';

import '../tokens/colors.dart';
import '../tokens/geometry.dart';
import '../tokens/typography.dart';

/// A two-state option drawn as text, as desktop editors show these.
class CfOptionToggle extends StatelessWidget {
  const CfOptionToggle({
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

/// A one-line field in the code font, with an optional count at its end:
/// the find bar's (Phase 2 W6) and the Search panel's (Phase 4 W6).
class CfCodeField extends StatelessWidget {
  const CfCodeField({
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
    this.keepKeyboard = true,
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

  /// Whether Enter keeps the keyboard up (the find bar) or lets it go (a
  /// field whose Enter shows results below it).
  final bool keepKeyboard;

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
          // With keepKeyboard, Enter keeps the keyboard: in the find bar it
          // steps to the next match, it does not end the search.
          onEditingComplete: keepKeyboard ? () {} : null,
        ),
      ],
    );
  }
}
