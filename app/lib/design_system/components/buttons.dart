/// Buttons: primary (ember), tonal, ghost. All ≥48 dp touch targets.
library;

import 'package:material_ui/material_ui.dart';

import '../tokens/colors.dart';
import '../tokens/geometry.dart';

enum CfButtonVariant { primary, tonal, ghost }

class CfButton extends StatelessWidget {
  const CfButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.variant = CfButtonVariant.primary,
    this.expanded = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final CfButtonVariant variant;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textStyle = Theme.of(context).textTheme.labelLarge;
    final (bg, fg, border) = switch (variant) {
      CfButtonVariant.primary => (
        colors.accentEmber,
        colors.onAccent,
        Colors.transparent,
      ),
      CfButtonVariant.tonal => (
        colors.accentEmberSoft,
        colors.accentEmber,
        Colors.transparent,
      ),
      CfButtonVariant.ghost => (
        Colors.transparent,
        colors.textSecondary,
        colors.borderSubtle,
      ),
    };
    final enabled = onPressed != null;
    final button = Material(
      color: enabled ? bg : colors.surfaceRaised,
      borderRadius: BorderRadius.circular(CfRadius.sm),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(CfRadius.sm),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: CfSpacing.minTouchTarget,
          ),
          padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CfRadius.sm),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: enabled ? fg : colors.textDisabled),
                const SizedBox(width: CfSpacing.sm),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle?.copyWith(
                    color: enabled ? fg : colors.textDisabled,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Square icon button with a mandatory tooltip (a11y) and 48 dp target by
/// default; dense chrome (top bars) may opt into 40 dp.
class CfIconButton extends StatelessWidget {
  const CfIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.size = 20,
    this.dimension = CfSpacing.minTouchTarget,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double size;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final enabled = onPressed != null;
    final fg = !enabled
        ? colors.textDisabled
        : selected
        ? colors.accentEmber
        : colors.textSecondary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? colors.accentEmberSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(CfRadius.sm),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(CfRadius.sm),
          child: SizedBox(
            width: dimension,
            height: dimension,
            child: Icon(icon, size: size, color: fg),
          ),
        ),
      ),
    );
  }
}
