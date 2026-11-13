/// Feedback components: banner, empty state, status chip.
library;

import 'package:material_ui/material_ui.dart';

import '../tokens/colors.dart';
import '../tokens/geometry.dart';
import '../tokens/icons.dart';
import 'buttons.dart';

enum CfBannerKind { info, warning, danger }

/// Inline banner for phase notices and honest capability labels. An action
/// sits under the message, at its end, so a narrow phone keeps the
/// message's full width; the dismiss cross stays beside it. A second
/// action (Phase 3 W5: a choice between two versions of a file) goes
/// before the first, and they wrap when the row is too narrow.
class CfBanner extends StatelessWidget {
  const CfBanner({
    super.key,
    required this.message,
    this.kind = CfBannerKind.info,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.onDismiss,
  });

  final String message;
  final CfBannerKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final (fg, icon) = switch (kind) {
      CfBannerKind.info => (colors.info, CfIcons.info),
      CfBannerKind.warning => (colors.warning, CfIcons.warning),
      CfBannerKind.danger => (colors.danger, CfIcons.error),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: CfSpacing.md,
        vertical: CfSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(CfRadius.sm),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: fg),
          ),
          const SizedBox(width: CfSpacing.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: CfSpacing.xs),
                  child: Text(
                    message,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (actionLabel != null && secondaryActionLabel != null)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: CfSpacing.xs,
                      children: [
                        CfButton(
                          label: secondaryActionLabel!,
                          variant: CfButtonVariant.ghost,
                          onPressed: onSecondaryAction,
                        ),
                        CfButton(
                          label: actionLabel!,
                          variant: CfButtonVariant.ghost,
                          onPressed: onAction,
                        ),
                      ],
                    ),
                  )
                else if (actionLabel != null)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: CfButton(
                      label: actionLabel!,
                      variant: CfButtonVariant.ghost,
                      onPressed: onAction,
                    ),
                  ),
              ],
            ),
          ),
          if (onDismiss != null)
            CfIconButton(
              icon: CfIcons.close,
              tooltip: 'Dismiss',
              size: 16,
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}

/// Designed empty state — never a bare spinner or blank pane.
class CfEmptyState extends StatelessWidget {
  const CfEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.phaseNote,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? phaseNote;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(CfSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: colors.accentEmberSoft,
                borderRadius: BorderRadius.circular(CfRadius.lg),
              ),
              child: Icon(icon, size: 28, color: colors.accentEmber),
            ),
            const SizedBox(height: CfSpacing.lg),
            Text(
              title,
              style: textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: CfSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                message,
                style: textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: CfSpacing.lg),
              CfButton(label: actionLabel!, onPressed: onAction),
            ],
            if (phaseNote != null) ...[
              const SizedBox(height: CfSpacing.md),
              Text(
                phaseNote!,
                style: textTheme.labelSmall?.copyWith(
                  color: colors.textDisabled,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small status chip (branch, runtime state, counters).
class CfStatusChip extends StatelessWidget {
  const CfStatusChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.onTap,
    this.tooltip,
  });

  final String label;
  final Color? color;
  final IconData? icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final fg = color ?? colors.textSecondary;
    final chip = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(CfRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: CfSpacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: fg),
              const SizedBox(width: CfSpacing.xs),
            ],
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: fg),
            ),
          ],
        ),
      ),
    );
    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: chip);
    }
    return chip;
  }
}
