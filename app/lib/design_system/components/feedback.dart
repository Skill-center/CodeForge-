/// Feedback components: banner, empty state, status chip.
library;

import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/geometry.dart';
import 'buttons.dart';

enum CfBannerKind { info, warning, danger }

/// Inline banner for phase notices and honest capability labels.
class CfBanner extends StatelessWidget {
  const CfBanner({
    super.key,
    required this.message,
    this.kind = CfBannerKind.info,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  final String message;
  final CfBannerKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final (fg, icon) = switch (kind) {
      CfBannerKind.info => (colors.info, Icons.info_outline),
      CfBannerKind.warning => (colors.warning, Icons.warning_amber_outlined),
      CfBannerKind.danger => (colors.danger, Icons.error_outline),
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
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: CfSpacing.xs),
              child: Text(message, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          if (actionLabel != null)
            CfButton(
              label: actionLabel!,
              variant: CfButtonVariant.ghost,
              onPressed: onAction,
            ),
          if (onDismiss != null)
            CfIconButton(
              icon: Icons.close,
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
            Text(title, style: textTheme.titleMedium, textAlign: TextAlign.center),
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
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
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
