/// The terminal panel (Phase 5 W3; docs/TERMINAL_ARCHITECTURE.md §3), on the
/// three-stop sheet the pane has had since Phase 1: tabs for the sessions
/// (new, rename, close, swipe between them), the terminal page (xterm.js),
/// and the extra-keys row with Copy and Paste. Its menu maximizes it (the
/// full stop) and restores it. Without a terminal host (tests, the honest
/// fake) it says so instead.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../application/shell_controller.dart';
import '../../../application/terminal/terminal_controller.dart';
import '../../../application/terminal/terminal_view.dart';
import '../../../core/terminal/extra_keys.dart';
import '../../../core/terminal/native_addons.dart';
import '../../../design_system/components/workbench_chrome.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/icons.dart';
import '../../../design_system/tokens/typography.dart';
import '../../../services/shell/shell_state.dart';
import '../terminal_dialogs.dart';
import 'terminal_surface_view.dart';

/// The header: a row of touch targets under a hairline.
const double _headerExtent = CfSpacing.minTouchTarget + CfSpacing.hairline;

/// The least room the terminal keeps above the extra-keys row: below it the
/// row is left out (the peek stop, a short landscape screen).
const double _minBodyWithKeys = 72;

/// A fling across the tabs faster than this switches tabs (logical px/s).
const double _swipeVelocity = 300;

class TerminalPane extends ConsumerWidget {
  const TerminalPane({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final panel = ref.watch(terminalControllerProvider);
    final active = panel.active;
    return Container(
      color: colors.surfaceSunken,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final keys =
              panel.available &&
              (active?.running ?? false) &&
              constraints.maxHeight >=
                  _headerExtent + CfSymbolToolbar.extent + _minBodyWithKeys;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TerminalHeader(panel: panel, onClose: onClose),
              Expanded(child: _TerminalBody(panel: panel)),
              if (keys) _ExtraKeysRow(panel: panel),
            ],
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------------ header

class _TerminalHeader extends ConsumerWidget {
  const _TerminalHeader({required this.panel, required this.onClose});

  final TerminalPanelState panel;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final controller = ref.read(terminalControllerProvider.notifier);
    final running = panel.tabs.where((tab) => tab.running).length;
    final stop = ref.watch(shellControllerProvider).terminalStop;
    final maximized = stop == TerminalStop.full;
    return Container(
      height: _headerExtent,
      padding: const EdgeInsets.only(left: CfSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfacePanel,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        children: [
          Icon(CfIcons.terminal, size: 14, color: colors.textSecondary),
          const SizedBox(width: CfSpacing.sm),
          if (panel.tabs.isEmpty)
            Expanded(
              child: Text(
                'TERMINAL',
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            Expanded(child: _TabStrip(panel: panel)),
          if (panel.available)
            _HeaderButton(
              key: const ValueKey('terminal_new'),
              icon: CfIcons.add,
              tooltip: 'New terminal',
              onTap: panel.canStart
                  ? () => unawaited(controller.newSession())
                  : null,
            ),
          if (panel.available && panel.tabs.isNotEmpty)
            PopupMenuButton<_MenuAction>(
              key: const ValueKey('terminal_menu'),
              tooltip: 'Terminal actions',
              icon: Icon(
                CfIcons.moreVert,
                size: 18,
                color: colors.textSecondary,
              ),
              onSelected: (action) =>
                  unawaited(_onMenu(context, ref, action, running: running)),
              itemBuilder: (context) => [
                if (panel.active != null)
                  const PopupMenuItem(
                    key: ValueKey('terminal_menu_close'),
                    value: _MenuAction.close,
                    child: Text('Close'),
                  ),
                if (panel.active != null)
                  const PopupMenuItem(
                    key: ValueKey('terminal_menu_rename'),
                    value: _MenuAction.rename,
                    child: Text('Rename'),
                  ),
                if (panel.active != null)
                  const PopupMenuItem(
                    key: ValueKey('terminal_menu_clear'),
                    value: _MenuAction.clear,
                    child: Text('Clear scrollback'),
                  ),
                if (!maximized)
                  const PopupMenuItem(
                    key: ValueKey('terminal_menu_maximize'),
                    value: _MenuAction.maximize,
                    child: Text('Maximize'),
                  ),
                if (maximized)
                  const PopupMenuItem(
                    key: ValueKey('terminal_menu_restore'),
                    value: _MenuAction.restore,
                    child: Text('Restore size'),
                  ),
                PopupMenuItem(
                  key: const ValueKey('terminal_menu_end_all'),
                  value: _MenuAction.endAll,
                  enabled: running > 0,
                  child: const Text('End all'),
                ),
              ],
            ),
          if (onClose != null)
            _HeaderButton(
              key: const ValueKey('terminal_close'),
              icon: CfIcons.keyboardArrowDown,
              tooltip: 'Hide terminal',
              onTap: onClose,
            ),
        ],
      ),
    );
  }

  Future<void> _onMenu(
    BuildContext context,
    WidgetRef ref,
    _MenuAction action, {
    required int running,
  }) async {
    final controller = ref.read(terminalControllerProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    final active = panel.active;
    switch (action) {
      case _MenuAction.close:
        if (active != null) {
          await closeTerminal(context, ref, active);
        }
      case _MenuAction.rename:
        if (active != null) {
          await renameTerminal(context, ref, active);
        }
      case _MenuAction.clear:
        await controller.clear();
      case _MenuAction.maximize:
        shell.setTerminalStop(TerminalStop.full);
      case _MenuAction.restore:
        shell.setTerminalStop(TerminalStop.half);
      case _MenuAction.endAll:
        if (await confirmEndAllTerminals(context, running)) {
          await controller.endAll();
        }
    }
  }
}

enum _MenuAction { close, rename, clear, maximize, restore, endAll }

/// Asks for [tab]'s new name and gives it.
Future<void> renameTerminal(
  BuildContext context,
  WidgetRef ref,
  TerminalTab tab,
) async {
  final name = await askTerminalName(context, tab.label);
  if (name != null) {
    ref.read(terminalControllerProvider.notifier).rename(tab.sessionId, name);
  }
}

/// Closes [tab], asking first while it runs.
Future<void> closeTerminal(
  BuildContext context,
  WidgetRef ref,
  TerminalTab tab,
) async {
  if (tab.running && !await confirmCloseTerminal(context, tab.label)) {
    return;
  }
  await ref.read(terminalControllerProvider.notifier).close(tab.sessionId);
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: CfSpacing.minTouchTarget,
          height: CfSpacing.minTouchTarget,
          child: Icon(
            icon,
            size: 18,
            color: onTap == null ? colors.textDisabled : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// The sessions' tabs, sharing the strip's width. A fling across them shows
/// the next or the previous; the shown one has its close button when there
/// is room (the menu's Close always works).
class _TabStrip extends ConsumerWidget {
  const _TabStrip({required this.panel});

  final TerminalPanelState panel;

  /// The least width at which the shown tab keeps a close button beside
  /// its name.
  static const double _closableWidth = 2 * CfSpacing.minTouchTarget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(terminalControllerProvider.notifier);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth / panel.tabs.length;
        return GestureDetector(
          key: const ValueKey('terminal_tabs'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity <= -_swipeVelocity) {
              controller.step(1);
            } else if (velocity >= _swipeVelocity) {
              controller.step(-1);
            }
          },
          child: Row(
            children: [
              for (final tab in panel.tabs)
                SizedBox(
                  width: width,
                  child: _TabChip(
                    tab: tab,
                    active: tab.sessionId == panel.activeId,
                    closable:
                        tab.sessionId == panel.activeId &&
                        width >= _closableWidth,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TabChip extends ConsumerWidget {
  const _TabChip({
    required this.tab,
    required this.active,
    required this.closable,
  });

  final TerminalTab tab;
  final bool active;
  final bool closable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final dot = tab.bell
        ? colors.warning
        : tab.running
        ? colors.success
        : colors.textDisabled;
    return Container(
      height: CfSpacing.minTouchTarget,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: active ? colors.accentEmber : const Color(0x00000000),
            width: 2,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              button: true,
              selected: active,
              label:
                  '${tab.label}, ${tab.ending ?? 'running'}'
                  '${tab.bell ? ', bell rang' : ''}',
              excludeSemantics: true,
              child: InkWell(
                key: ValueKey('terminal_tab_${tab.sessionId}'),
                onTap: () => ref
                    .read(terminalControllerProvider.notifier)
                    .activate(tab.sessionId),
                onLongPress: () => unawaited(renameTerminal(context, ref, tab)),
                child: Padding(
                  padding: const EdgeInsets.only(left: CfSpacing.sm),
                  child: Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: dot,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: CfSpacing.xs),
                      Expanded(
                        child: Text(
                          tab.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelMedium?.copyWith(
                            color: active
                                ? colors.textPrimary
                                : colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (closable)
            Tooltip(
              message: 'Close ${tab.label}',
              child: InkWell(
                key: ValueKey('terminal_tab_close_${tab.sessionId}'),
                onTap: () => unawaited(closeTerminal(context, ref, tab)),
                child: SizedBox(
                  width: CfSpacing.minTouchTarget,
                  height: CfSpacing.minTouchTarget,
                  child: Icon(
                    CfIcons.close,
                    size: 14,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- body

class _TerminalBody extends ConsumerWidget {
  const _TerminalBody({required this.panel});

  final TerminalPanelState panel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final controller = ref.read(terminalControllerProvider.notifier);
    if (!panel.available) {
      return SingleChildScrollView(
        key: const ValueKey('terminal_unavailable'),
        padding: const EdgeInsets.all(CfSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              r'codeforge:~$ ',
              style: CfTypography.code(
                colors,
                fontSize: 13,
              ).copyWith(color: colors.accentEmber),
            ),
            const SizedBox(height: CfSpacing.sm),
            Text(
              panel.unavailableReason,
              style: CfTypography.code(
                colors,
                fontSize: 12,
              ).copyWith(color: colors.syntaxComment),
            ),
          ],
        ),
      );
    }
    final message = panel.message;
    if (panel.tabs.isEmpty) {
      return SingleChildScrollView(
        key: const ValueKey('terminal_empty'),
        padding: const EdgeInsets.all(CfSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message ?? 'A shell in the Linux runtime.',
              key: message == null ? null : const ValueKey('terminal_message'),
              style: textTheme.bodySmall?.copyWith(
                color: message == null ? colors.textSecondary : colors.danger,
              ),
            ),
            const SizedBox(height: CfSpacing.sm),
            FilledButton.icon(
              key: const ValueKey('terminal_new_empty'),
              onPressed: panel.canStart
                  ? () => unawaited(controller.newSession())
                  : null,
              icon: const Icon(CfIcons.add, size: 16),
              label: Text(panel.starting ? 'Starting…' : 'New terminal'),
            ),
          ],
        ),
      );
    }
    final active = panel.active;
    final ending = active?.ending;
    return Stack(
      fit: StackFit.expand,
      children: [
        const TerminalSurfaceView(),
        if (panel.viewPhase == TerminalViewPhase.failed)
          ColoredBox(
            color: colors.surfaceSunken,
            child: SingleChildScrollView(
              key: const ValueKey('terminal_page_failed'),
              padding: const EdgeInsets.all(CfSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    panel.viewMessage ?? 'The terminal could not start.',
                    style: textTheme.bodySmall?.copyWith(color: colors.danger),
                  ),
                  const SizedBox(height: CfSpacing.sm),
                  TextButton(
                    key: const ValueKey('terminal_page_retry'),
                    onPressed: () => unawaited(controller.retryPage()),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          )
        else if (panel.viewPhase != TerminalViewPhase.ready)
          ColoredBox(
            color: colors.surfaceSunken,
            child: Center(
              child: Text(
                'Starting the terminal…',
                key: const ValueKey('terminal_page_starting'),
                style: textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
        if (message != null || active?.nativeAddon != null)
          Align(
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (message != null)
                  _Banner(
                    key: const ValueKey('terminal_message'),
                    text: message,
                    color: colors.danger,
                    actionLabel: 'Dismiss',
                    actionKey: const ValueKey('terminal_message_dismiss'),
                    onAction: controller.dismissMessage,
                  ),
                // A native build failed for want of a compiler (Phase 5 W4).
                if ((active, active?.nativeAddon) case (
                  final tab?,
                  final kind?,
                ))
                  _Banner(
                    key: const ValueKey('terminal_native_addon'),
                    text: nativeAddonMessage(kind),
                    color: colors.warning,
                    maxLines: 5,
                    actionLabel: 'Dismiss',
                    actionKey: const ValueKey('terminal_native_addon_dismiss'),
                    onAction: () =>
                        controller.dismissNativeAddon(tab.sessionId),
                  ),
              ],
            ),
          ),
        if (active != null && ending != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: _Banner(
              key: const ValueKey('terminal_exited'),
              text: '${active.label} $ending.',
              color: colors.textSecondary,
              actionLabel: 'Close',
              actionKey: const ValueKey('terminal_exited_close'),
              onAction: () => unawaited(controller.close(active.sessionId)),
            ),
          ),
      ],
    );
  }
}

/// A one-line notice over the terminal, with one action.
class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.text,
    required this.color,
    required this.actionLabel,
    required this.actionKey,
    required this.onAction,
    this.maxLines = 2,
  });

  final String text;
  final Color color;
  final String actionLabel;
  final Key actionKey;
  final VoidCallback onAction;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: CfSpacing.minTouchTarget),
      padding: const EdgeInsets.only(left: CfSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfacePanel,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          TextButton(
            key: actionKey,
            onPressed: onAction,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- extra keys

class _ExtraKeysRow extends ConsumerWidget {
  const _ExtraKeysRow({required this.panel});

  final TerminalPanelState panel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(terminalControllerProvider.notifier);

    CfToolbarKey keyFor(ExtraKey key) {
      return CfToolbarKey(
        id: 'terminal_${key.id}',
        semanticLabel: key.semanticLabel,
        label: _iconFor(key.id) == null ? key.label : null,
        icon: _iconFor(key.id),
        toggled: switch (key.kind) {
          ExtraKeyKind.ctrl => panel.ctrl,
          ExtraKeyKind.alt => panel.alt,
          ExtraKeyKind.key => null,
        },
        onPressed: switch (key.kind) {
          ExtraKeyKind.ctrl => controller.toggleCtrl,
          ExtraKeyKind.alt => controller.toggleAlt,
          ExtraKeyKind.key => () => unawaited(controller.sendKey(key.key!)),
        },
      );
    }

    return CfSymbolToolbar(
      key: const ValueKey('terminal_keys'),
      keys: [for (final key in terminalExtraKeys) keyFor(key)],
      trailing: [
        if (panel.selection) ...[
          CfToolbarKey(
            id: 'terminal_copy',
            semanticLabel: 'Copy',
            icon: CfIcons.contentCopy,
            onPressed: () => unawaited(controller.copy()),
          ),
          CfToolbarKey(
            id: 'terminal_select_all',
            semanticLabel: 'Select all',
            icon: CfIcons.selectAll,
            onPressed: () => unawaited(controller.selectAll()),
          ),
        ],
        CfToolbarKey(
          id: 'terminal_paste',
          semanticLabel: 'Paste',
          icon: CfIcons.contentPaste,
          onPressed: () => unawaited(controller.paste()),
        ),
        CfToolbarKey(
          id: 'terminal_keyboard',
          semanticLabel: panel.focused
              ? 'Hide the keyboard'
              : 'Show the keyboard',
          icon: panel.focused ? CfIcons.keyboardHide : CfIcons.keyboard,
          onPressed: () => unawaited(controller.focus(focused: !panel.focused)),
        ),
      ],
    );
  }

  static IconData? _iconFor(String id) => switch (id) {
    'left' => CfIcons.keyboardArrowLeft,
    'up' => CfIcons.keyboardArrowUp,
    'down' => CfIcons.keyboardArrowDown,
    'right' => CfIcons.keyboardArrowRight,
    _ => null,
  };
}
