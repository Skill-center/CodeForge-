/// Settings row + section header used by every settings page.
library;

import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/geometry.dart';

class CfSettingsTile extends StatelessWidget {
  const CfSettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: CfSpacing.minTouchTarget),
        padding: const EdgeInsets.symmetric(
          horizontal: CfSpacing.lg,
          vertical: CfSpacing.md,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              IconTheme(
                data: IconThemeData(color: colors.textSecondary, size: 20),
                child: leading!,
              ),
              const SizedBox(width: CfSpacing.lg),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: textTheme.bodyMedium),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: CfSpacing.md),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class CfSectionHeader extends StatelessWidget {
  const CfSectionHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CfSpacing.lg,
        CfSpacing.xl,
        CfSpacing.lg,
        CfSpacing.sm,
      ),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.accentEmber,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
