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

/// Horizontal editor tab strip with dirty dots and close affordances. It
/// scrolls the active tab into view when it changes, so a tab chosen from
/// the keyboard or the explorer is never off-screen. Every tab is built
/// (no lazy list) so that any of them can be scrolled to; a phone holds
/// tens of tabs, not thousands.
class CfTabStrip extends StatefulWidget {
  const CfTabStrip({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onActivate,
    required this.onClose,
    this.trailing,
  });

  final List<CfTab> tabs;
  final String? activeId;
  final ValueChanged<String> onActivate;
  final ValueChanged<String> onClose;

  /// Pinned after the tabs, outside their scroll (the editor's save action).
  final Widget? trailing;

  @override
  State<CfTabStrip> createState() => _CfTabStripState();
}

class _CfTabStripState extends State<CfTabStrip> {
  final Map<String, GlobalKey> _tabKeys = {};

  @override
  void initState() {
    super.initState();
    _revealActive();
  }

  @override
  void didUpdateWidget(CfTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = {for (final tab in widget.tabs) tab.id};
    _tabKeys.removeWhere((id, _) => !ids.contains(id));
    if (widget.activeId != oldWidget.activeId ||
        widget.tabs.length != oldWidget.tabs.length) {
      _revealActive();
    }
  }

  /// After the next frame, scrolls just enough to show the active tab.
  void _revealActive() {
    final id = widget.activeId;
    if (id == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tabContext = _tabKeys[id]?.currentContext;
      if (!mounted || tabContext == null) {
        return;
      }
      // Each policy moves only when that edge is hidden; jumps, no motion.
      Scrollable.ensureVisible(
        tabContext,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
      Scrollable.ensureVisible(
        tabContext,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final trailing = widget.trailing;
    final strip = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final tab in widget.tabs) _tab(context, colors, tab)],
      ),
    );
    return Container(
      height: CfSpacing.tabStripHeight + CfSpacing.hairline,
      decoration: BoxDecoration(
        color: colors.surfacePanel,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: trailing == null
          ? strip
          : Row(
              children: [
                Expanded(child: strip),
                trailing,
              ],
            ),
    );
  }

  Widget _tab(BuildContext context, CfColors colors, CfTab tab) {
    final active = tab.id == widget.activeId;
    return Material(
      key: _tabKeys.putIfAbsent(tab.id, GlobalKey.new),
      color: active ? colors.surfaceBase : colors.surfacePanel,
      child: InkWell(
        onTap: () => widget.onActivate(tab.id),
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
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: active ? colors.textPrimary : colors.textSecondary,
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: 'Close ${tab.label}',
                child: InkWell(
                  key: ValueKey('tab_close_${tab.id}'),
                  onTap: () => widget.onClose(tab.id),
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

/// One key of a [CfSymbolToolbar]: a symbol in the code font, or an icon.
@immutable
class CfToolbarKey {
  const CfToolbarKey({
    required this.id,
    required this.semanticLabel,
    this.label,
    this.icon,
    this.onPressed,
    this.onLongPress,
  }) : assert(label != null || icon != null, 'a key needs a label or icon');

  /// Unique within the toolbar; the key's widget key is `toolbar_<id>`.
  final String id;

  /// What a screen reader announces.
  final String semanticLabel;

  final String? label;
  final IconData? icon;

  /// Null disables the key.
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
}

/// The symbol toolbar above the soft keyboard (Phase 2 W6): a scrolling row
/// of 48 dp keys, with [trailing] keys pinned at its end. No key can take
/// focus, so whatever has the keyboard keeps it while keys are tapped. The
/// terminal's extra-keys row is meant to reuse it (Phase 5).
class CfSymbolToolbar extends StatelessWidget {
  const CfSymbolToolbar({
    super.key,
    required this.keys,
    this.trailing = const [],
  });

  /// The toolbar's height: a row of keys under a hairline.
  static const double extent =
      CfSpacing.symbolToolbarHeight + CfSpacing.hairline;

  final List<CfToolbarKey> keys;
  final List<CfToolbarKey> trailing;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return ExcludeFocus(
      child: Container(
        height: extent,
        decoration: BoxDecoration(
          color: colors.surfacePanel,
          border: Border(top: BorderSide(color: colors.borderSubtle)),
        ),
        child: Row(
          children: [
            Expanded(
              child: ListView(
                key: const ValueKey('toolbar_keys'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: CfSpacing.xs),
                children: [for (final spec in keys) _ToolbarKeyButton(spec)],
              ),
            ),
            if (trailing.isNotEmpty) ...[
              VerticalDivider(
                width: CfSpacing.hairline,
                thickness: CfSpacing.hairline,
                color: colors.borderSubtle,
              ),
              for (final spec in trailing) _ToolbarKeyButton(spec),
            ],
          ],
        ),
      ),
    );
  }
}

class _ToolbarKeyButton extends StatelessWidget {
  const _ToolbarKeyButton(this.spec);

  final CfToolbarKey spec;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final enabled = spec.onPressed != null;
    final foreground = enabled ? colors.textPrimary : colors.textDisabled;
    final icon = spec.icon;
    final label = spec.label ?? '';
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: spec.semanticLabel,
      child: InkWell(
        key: ValueKey('toolbar_${spec.id}'),
        onTap: spec.onPressed,
        onLongPress: enabled ? spec.onLongPress : null,
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(CfRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: CfSpacing.minTouchTarget,
            minHeight: CfSpacing.minTouchTarget,
          ),
          // The touch target is the full 48 dp row; the key's face is drawn
          // inset within it.
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 2,
              vertical: CfSpacing.xs,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceRaised,
                borderRadius: BorderRadius.circular(CfRadius.sm),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: CfSpacing.sm),
                child: Center(
                  widthFactor: 1,
                  child: ExcludeSemantics(
                    child: icon != null
                        ? Icon(icon, size: 20, color: foreground)
                        : Text(
                            label,
                            maxLines: 1,
                            style: CfTypography.code(
                              colors,
                              fontSize: 15,
                            ).copyWith(color: foreground),
                          ),
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
