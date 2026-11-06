/// Workbench chrome: tab strip, activity bar/rail, status strip,
/// symbol toolbar. These are the signature Forge surfaces.
library;

import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/geometry.dart';
import '../tokens/typography.dart';

/// One tab in the editor tab strip.
final class CfTab {
  const CfTab({
    required this.id,
    required this.label,
    this.dirty = false,
    this.icon,
  });

  final String id;
  final String label;
  final bool dirty;
  final IconData? icon;
}

/// Horizontal editor tab strip with dirty dots and close affordances.
class CfTabStrip extends StatelessWidget {
  const CfTabStrip({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onActivate,
    required this.onClose,
  });

  final List<CfTab> tabs;
  final String? activeId;
  final ValueChanged<String> onActivate;
  final ValueChanged<String> onClose;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Container(
      height: CfSpacing.tabStripHeight + CfSpacing.hairline,
      decoration: BoxDecoration(
        color: colors.surfacePanel,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        itemBuilder: (context, index) {
          final tab = tabs[index];
          final active = tab.id == activeId;
          return Material(
            color: active ? colors.surfaceBase : colors.surfacePanel,
            child: InkWell(
              onTap: () => onActivate(tab.id),
              child: Container(
                constraints: const BoxConstraints(minWidth: 96, maxWidth: 200),
                padding: const EdgeInsets.only(left: CfSpacing.md),
                // Painted over the tab instead of insetting it, so the tab
                // and its close button stay a full 48 dp tall.
                foregroundDecoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: active ? colors.accentEmber : Colors.transparent,
                      width: 2,
                    ),
                    right: BorderSide(color: colors.borderSubtle),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tab.icon != null) ...[
                      Icon(tab.icon, size: 14, color: colors.textSecondary),
                      const SizedBox(width: CfSpacing.xs + 2),
                    ],
                    Flexible(
                      child: Text(
                        tab.label,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: active
                                  ? colors.textPrimary
                                  : colors.textSecondary,
                            ),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Close ${tab.label}',
                      child: InkWell(
                        key: ValueKey('tab_close_${tab.id}'),
                        onTap: () => onClose(tab.id),
                        child: SizedBox(
                          width: CfSpacing.minTouchTarget,
                          height: CfSpacing.tabStripHeight,
                          child: Center(
                            child: tab.dirty
                                ? Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: colors.accentEmber,
                                      shape: BoxShape.circle,
                                    ),
                                  )
                                : Icon(
                                    Icons.close,
                                    size: 14,
                                    color: colors.textSecondary,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One destination in the activity bar / nav rail.
final class CfActivity {
  const CfActivity({
    required this.id,
    required this.icon,
    required this.label,
    this.enabled = true,
  });

  final String id;
  final IconData icon;
  final String label;
  final bool enabled;
}

/// Bottom activity bar (compact portrait).
class CfActivityBar extends StatelessWidget {
  const CfActivityBar({
    super.key,
    required this.activities,
    required this.activeId,
    required this.onSelect,
  });

  final List<CfActivity> activities;
  final String? activeId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Container(
      height: CfSpacing.activityBarHeight,
      decoration: BoxDecoration(
        color: colors.surfacePanel,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        children: [
          for (final activity in activities)
            Expanded(
              child: _ActivityButton(
                activity: activity,
                selected: activity.id == activeId,
                onSelect: onSelect,
              ),
            ),
        ],
      ),
    );
  }
}

/// Vertical navigation rail (landscape / tablet).
class CfNavRail extends StatelessWidget {
  const CfNavRail({
    super.key,
    required this.activities,
    required this.activeId,
    required this.onSelect,
    this.trailing = const [],
  });

  final List<CfActivity> activities;
  final String? activeId;
  final ValueChanged<String> onSelect;
  final List<CfActivity> trailing;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Container(
      width: CfSpacing.navRailWidth,
      decoration: BoxDecoration(
        color: colors.surfacePanel,
        border: Border(right: BorderSide(color: colors.borderSubtle)),
      ),
      child: Column(
        children: [
          // Activities scroll when the rail is short (soft keyboard up on a
          // landscape phone); the trailing entries stay pinned at the bottom.
          Expanded(
            child: ListView(
              primary: false,
              padding: const EdgeInsets.only(top: CfSpacing.sm),
              children: [
                for (final activity in activities)
                  _ActivityButton(
                    activity: activity,
                    selected: activity.id == activeId,
                    onSelect: onSelect,
                  ),
              ],
            ),
          ),
          for (final activity in trailing)
            _ActivityButton(
              activity: activity,
              selected: activity.id == activeId,
              onSelect: onSelect,
            ),
          const SizedBox(height: CfSpacing.sm),
        ],
      ),
    );
  }
}

class _ActivityButton extends StatelessWidget {
  const _ActivityButton({
    required this.activity,
    required this.selected,
    required this.onSelect,
  });

  final CfActivity activity;
  final bool selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final fg = !activity.enabled
        ? colors.textDisabled
        : selected
        ? colors.accentEmber
        : colors.textSecondary;
    // The visible caption is the label: the tooltip and the caption Text are
    // excluded from semantics so screen readers announce it once.
    return Tooltip(
      message: activity.label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: selected,
        label: activity.label,
        child: InkWell(
          key: ValueKey('activity_${activity.id}'),
          onTap: activity.enabled ? () => onSelect(activity.id) : null,
          // Full width of the bar slot / rail, not just the caption (G7).
          child: SizedBox(
            width: double.infinity,
            height: CfSpacing.activityBarHeight,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(activity.icon, size: 20, color: fg),
                const SizedBox(height: 2),
                ExcludeSemantics(
                  child: Text(
                    activity.label,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(fontSize: 10, color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom status strip: workspace, branch, runtime, cursor, language.
class CfStatusStrip extends StatelessWidget {
  const CfStatusStrip({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Container(
      height: CfSpacing.statusStripHeight,
      decoration: BoxDecoration(
        color: colors.surfacePanel,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: CfSpacing.xs),
      child: Row(children: children),
    );
  }
}

/// Editor symbol toolbar. In Phase 1 the keys are visibly disabled with an
/// honest phase note — no fake editing.
class CfSymbolToolbar extends StatelessWidget {
  const CfSymbolToolbar({
    super.key,
    this.enabled = false,
    this.onSymbol,
    this.phaseNote = 'Editor arrives in Phase 2',
  });

  static const List<String> symbols = [
    'Esc',
    'Tab',
    '{',
    '}',
    '[',
    ']',
    '(',
    ')',
    '<',
    '>',
    ';',
    '=',
    '_',
    '-',
  ];

  final bool enabled;
  final ValueChanged<String>? onSymbol;
  final String phaseNote;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Tooltip(
      message: enabled ? 'Symbol toolbar' : phaseNote,
      child: Container(
        height: CfSpacing.symbolToolbarHeight,
        decoration: BoxDecoration(
          color: colors.surfacePanel,
          border: Border(top: BorderSide(color: colors.borderSubtle)),
        ),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: CfSpacing.sm),
          children: [
            for (final symbol in symbols)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 2,
                  vertical: CfSpacing.xs,
                ),
                child: Material(
                  color: colors.surfaceRaised,
                  borderRadius: BorderRadius.circular(CfRadius.sm),
                  child: InkWell(
                    onTap: enabled ? () => onSymbol?.call(symbol) : null,
                    borderRadius: BorderRadius.circular(CfRadius.sm),
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 40),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: CfSpacing.sm,
                      ),
                      child: Text(
                        symbol,
                        style: CfTypography.code(colors, fontSize: 13).copyWith(
                          color: enabled
                              ? colors.textPrimary
                              : colors.textDisabled,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
