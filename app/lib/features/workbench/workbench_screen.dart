/// The adaptive workbench (docs/UI_DESIGN_SYSTEM.md §4, gate G2/G7).
///
/// compact portrait : editor + bottom activity bar + 3-stop terminal sheet
/// compact landscape: nav rail + editor + docked terminal
/// medium/expanded  : nav rail + resizable sidebar + editor + docked terminal
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/editor_tabs_controller.dart';
import '../../application/providers.dart';
import '../../application/shell_controller.dart';
import '../../core/platform/breakpoints.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/components/workbench_chrome.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../services/shell/shell_state.dart';
import '../palette/command_palette.dart';
import 'panels/editor_pane.dart';
import 'panels/explorer_panel.dart';
import 'panels/placeholder_panels.dart';
import 'panels/terminal_pane.dart';

const List<CfActivity> _activities = [
  CfActivity(id: 'explorer', icon: Icons.folder_outlined, label: 'Files'),
  CfActivity(id: 'search', icon: Icons.search, label: 'Search'),
  CfActivity(id: 'run', icon: Icons.play_arrow_outlined, label: 'Run'),
  CfActivity(id: 'git', icon: Icons.commit, label: 'Git'),
  CfActivity(id: 'extensions', icon: Icons.extension_outlined, label: 'Ext'),
];

const CfActivity _settingsActivity = CfActivity(
  id: 'settings',
  icon: Icons.settings_outlined,
  label: 'Settings',
);

ShellActivity _activityFromId(String id) {
  return ShellActivity.values.firstWhere(
    (a) => a.name == id,
    orElse: () => ShellActivity.explorer,
  );
}

class WorkbenchScreen extends ConsumerStatefulWidget {
  const WorkbenchScreen({super.key});

  @override
  ConsumerState<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

class _WorkbenchScreenState extends ConsumerState<WorkbenchScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(shellControllerProvider.notifier).setLastRoute('/workspace');
      _ensureWorkspace();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Flush layout memory before Android may kill the process (G5).
      ref.read(shellControllerProvider.notifier).flush();
    }
  }

  Future<void> _ensureWorkspace() async {
    final files = ref.read(fileServiceProvider);
    await files.openDemoWorkspace();
    if (!mounted) return;
    final tabs = ref.read(editorTabsProvider);
    if (tabs.openPaths.isEmpty) {
      await ref.read(editorTabsProvider.notifier).open('main.js');
    }
  }

  void _onActivitySelected(String id) {
    if (id == 'settings') {
      context.go('/settings');
      return;
    }
    final activity = _activityFromId(id);
    final shell = ref.read(shellControllerProvider);
    final size = MediaQuery.sizeOf(context);
    final form = formFactorFor(size.width);
    final compactPortrait =
        form == CfFormFactor.compact &&
        !isLandscapeSurface(size.width, size.height);
    if (compactPortrait) {
      // Re-tapping the active activity closes its sheet.
      if (shell.activity == activity && _sheetOpen) {
        Navigator.of(context).maybePop();
        return;
      }
      ref.read(shellControllerProvider.notifier).setActivity(activity);
      _openActivitySheet(activity);
    } else {
      ref.read(shellControllerProvider.notifier).setActivity(activity);
    }
  }

  bool _sheetOpen = false;

  void _openActivitySheet(ShellActivity activity) {
    _sheetOpen = true;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, controller) => Column(
          children: [
            const SizedBox(height: CfSpacing.sm),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: CfColors.of(context).borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: _ActivityBody(
                activity: activity,
                onFileOpened: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    ).whenComplete(() => _sheetOpen = false);
  }

  void _toggleTerminal() {
    final shell = ref.read(shellControllerProvider);
    final notifier = ref.read(shellControllerProvider.notifier);
    notifier.setTerminalStop(
      shell.terminalStop == TerminalStop.closed
          ? TerminalStop.half
          : TerminalStop.closed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final form = formFactorFor(size.width);
    final landscape = isLandscapeSurface(size.width, size.height);
    final compactPortrait = form == CfFormFactor.compact && !landscape;
    final shell = ref.watch(shellControllerProvider);

    // Top-level routes are reached with go(), so there is nothing beneath
    // them to pop: system back (incl. predictive back) returns home, like the
    // home button, instead of leaving the app (G2). Sheets and dialogs are
    // routes of their own and still close first.
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/');
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(
            LogicalKeyboardKey.keyP,
            control: true,
            shift: true,
          ): () =>
              showCommandPalette(context),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: compactPortrait
                  ? _CompactPortraitLayout(
                      shell: shell,
                      onToggleTerminal: _toggleTerminal,
                    )
                  : _DockedLayout(
                      shell: shell,
                      form: form,
                      onActivitySelected: _onActivitySelected,
                      onToggleTerminal: _toggleTerminal,
                    ),
            ),
            bottomNavigationBar: compactPortrait
                ? SafeArea(
                    top: false,
                    child: CfActivityBar(
                      activities: _activities,
                      activeId: shell.activity.name,
                      onSelect: _onActivitySelected,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// Compact portrait: top bar, editor, optional terminal stop, status strip.
class _CompactPortraitLayout extends ConsumerWidget {
  const _CompactPortraitLayout({
    required this.shell,
    required this.onToggleTerminal,
  });

  final ShellState shell;
  final VoidCallback onToggleTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final height = MediaQuery.sizeOf(context).height;
    // Clamp so the editor always keeps space even at the full stop on
    // short screens — the zero-overflow gate covers every stop.
    final maxTerminal = (height - 320).clamp(0.0, double.infinity).toDouble();
    final terminalHeight = switch (shell.terminalStop) {
      TerminalStop.closed => 0.0,
      TerminalStop.peek => 96.0,
      TerminalStop.half => height * 0.4,
      TerminalStop.full => height * 0.7,
    }.clamp(0.0, maxTerminal).toDouble();
    return Column(
      children: [
        _WorkbenchTopBar(onToggleTerminal: onToggleTerminal),
        const Expanded(child: EditorPane()),
        if (terminalHeight > 0)
          SizedBox(
            height: terminalHeight,
            child: TerminalPane(
              onClose: () => ref
                  .read(shellControllerProvider.notifier)
                  .setTerminalStop(TerminalStop.closed),
            ),
          ),
        const _StatusStripRow(),
      ],
    );
  }
}

/// Landscape/tablet: rail + optional sidebar + editor + docked terminal.
class _DockedLayout extends ConsumerWidget {
  const _DockedLayout({
    required this.shell,
    required this.form,
    required this.onActivitySelected,
    required this.onToggleTerminal,
  });

  final ShellState shell;
  final CfFormFactor form;
  final ValueChanged<String> onActivitySelected;
  final VoidCallback onToggleTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showSidebar = form != CfFormFactor.compact;
    // Keep editor space on short landscape surfaces; below 60 dp the dock
    // is hidden entirely rather than overflowing.
    final height = MediaQuery.sizeOf(context).height;
    final terminalHeight = shell.terminalHeight
        .clamp(0.0, (height - 320).clamp(0.0, double.infinity))
        .toDouble();
    final terminalOpen =
        shell.terminalStop != TerminalStop.closed && terminalHeight >= 60;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CfNavRail(
          activities: _activities,
          activeId: shell.activity.name,
          onSelect: onActivitySelected,
          trailing: const [_settingsActivity],
        ),
        if (showSidebar) ...[
          SizedBox(
            width: shell.sidebarWidth,
            child: _ActivityBody(activity: shell.activity),
          ),
          _VerticalResizeHandle(
            onDrag: (dx) => ref
                .read(shellControllerProvider.notifier)
                .setSidebarWidth(shell.sidebarWidth + dx),
          ),
        ],
        Expanded(
          child: Column(
            children: [
              _WorkbenchTopBar(onToggleTerminal: onToggleTerminal),
              const Expanded(child: EditorPane()),
              if (terminalOpen) ...[
                _HorizontalResizeHandle(
                  onDrag: (dy) => ref
                      .read(shellControllerProvider.notifier)
                      .setTerminalHeight(shell.terminalHeight - dy),
                ),
                SizedBox(
                  height: terminalHeight,
                  child: TerminalPane(
                    onClose: () => ref
                        .read(shellControllerProvider.notifier)
                        .setTerminalStop(TerminalStop.closed),
                  ),
                ),
              ],
              const _StatusStripRow(),
            ],
          ),
        ),
      ],
    );
  }
}

class _WorkbenchTopBar extends ConsumerWidget {
  const _WorkbenchTopBar({required this.onToggleTerminal});

  final VoidCallback onToggleTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      height: CfSpacing.minTouchTarget + CfSpacing.hairline,
      padding: const EdgeInsets.symmetric(horizontal: CfSpacing.sm),
      decoration: BoxDecoration(
        color: colors.surfacePanel,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        children: [
          CfIconButton(
            key: const ValueKey('workbench_home'),
            icon: Icons.hardware,
            tooltip: 'CodeForge home',
            size: 18,
            onPressed: () => context.go('/'),
          ),
          Expanded(
            child: Text(
              'Demo Workspace',
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelMedium,
            ),
          ),
          CfIconButton(
            key: const ValueKey('palette_button'),
            icon: Icons.chevron_right,
            tooltip: 'Command palette (Ctrl+Shift+P)',
            size: 18,
            onPressed: () => showCommandPalette(context),
          ),
          CfIconButton(
            key: const ValueKey('terminal_toggle'),
            icon: Icons.terminal,
            tooltip: 'Toggle terminal',
            size: 18,
            onPressed: onToggleTerminal,
          ),
        ],
      ),
    );
  }
}

class _StatusStripRow extends ConsumerWidget {
  const _StatusStripRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final tabs = ref.watch(editorTabsProvider);
    final activeDoc = tabs.activePath == null
        ? null
        : tabs.documents[tabs.activePath];
    return CfStatusStrip(
      children: [
        const CfStatusChip(
          key: ValueKey('status_branch'),
          icon: Icons.fork_right,
          label: 'main',
          tooltip: 'Git arrives in Phase 6',
        ),
        const Spacer(),
        if (activeDoc != null) ...[
          CfStatusChip(label: activeDoc.language),
          if (activeDoc.dirty)
            CfStatusChip(label: '●', color: colors.accentEmber),
        ],
        CfStatusChip(
          icon: Icons.circle,
          label: 'no runtime',
          color: colors.textDisabled,
          tooltip: 'Runtime installs in Phase 4',
        ),
      ],
    );
  }
}

class _ActivityBody extends StatelessWidget {
  const _ActivityBody({required this.activity, this.onFileOpened});

  final ShellActivity activity;
  final VoidCallback? onFileOpened;

  @override
  Widget build(BuildContext context) {
    return switch (activity) {
      ShellActivity.explorer => ExplorerPanel(onFileOpened: onFileOpened),
      ShellActivity.search => const SearchPanel(),
      ShellActivity.git => const GitPanel(),
      ShellActivity.extensions => const ExtensionsPanel(),
      ShellActivity.run => const RunPanel(),
    };
  }
}

class _VerticalResizeHandle extends StatelessWidget {
  const _VerticalResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: SizedBox(
          width: 6,
          child: Center(
            child: SizedBox(
              width: 1,
              child: ColoredBox(color: colors.borderSubtle),
            ),
          ),
        ),
      ),
    );
  }
}

class _HorizontalResizeHandle extends StatelessWidget {
  const _HorizontalResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        child: SizedBox(
          height: 6,
          child: Center(
            child: SizedBox(
              height: 1,
              child: ColoredBox(color: colors.borderSubtle),
            ),
          ),
        ),
      ),
    );
  }
}
