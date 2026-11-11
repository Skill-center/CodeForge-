/// The adaptive workbench (docs/UI_DESIGN_SYSTEM.md §4, gate G2/G7).
///
/// compact portrait : editor + bottom activity bar + 3-stop terminal sheet
/// compact landscape: nav rail + editor + docked terminal
/// medium/expanded  : nav rail + resizable sidebar + editor + docked terminal
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/documents/document_controller.dart';
import '../../application/editor/editor_providers.dart';
import '../../application/editor/find_controller.dart';
import '../../application/shell_controller.dart';
import '../../application/workbench_intents.dart';
import '../../application/workspace_controller.dart';
import '../../core/errors/failure.dart';
import '../../core/files/workspace_location.dart';
import '../../core/platform/breakpoints.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/components/workbench_chrome.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../services/contracts.dart';
import '../../services/shell/shell_state.dart';
import '../palette/command_palette.dart';
import 'editor_actions.dart';
import 'file_actions.dart';
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
  StreamSubscription<WorkbenchIntent>? _intents;

  /// Rotating swaps the portrait layout for the docked one. With this key
  /// the editor pane moves across instead of being rebuilt, so the page
  /// keeps every document's undo history and does not reload. Owned by
  /// this state, so two workbenches during a route change never share it.
  final GlobalKey _editorPaneKey = GlobalKey(debugLabel: 'editor pane');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Shortcuts forwarded by the editor page and palette commands arrive
    // as intents; this screen can show the dialogs they need.
    _intents = ref.read(workbenchIntentsProvider).stream.listen(_onIntent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(shellControllerProvider.notifier).setLastRoute('/workspace');
      _ensureWorkspace();
    });
  }

  @override
  void dispose() {
    unawaited(_intents?.cancel());
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

  /// Opens the workspace and reopens the last session's tabs, or the demo
  /// project's main.js the first time. A workspace that went missing or
  /// lost its access (a cold start that restored the workbench) lands on
  /// Home, where its entry in the recents says so (Phase 3 W3); other
  /// failures show in the explorer.
  Future<void> _ensureWorkspace() async {
    final opened = await ref.read(workspaceControllerProvider.notifier).open();
    if (!mounted) {
      return;
    }
    if (opened case Err<WorkspaceRef>(:final failure)) {
      if (failure is FileFailure &&
          (failure.problem == FileProblem.folderMissing ||
              failure.problem == FileProblem.accessLost)) {
        final messenger = ScaffoldMessenger.of(context);
        context.go('/');
        messenger.showSnackBar(SnackBar(content: Text(failure.message)));
      }
      return;
    }
    if (opened is! Ok<WorkspaceRef>) {
      return;
    }
    await ref
        .read(documentControllerProvider.notifier)
        .restoreTabs(
          fallback: opened.value.id == demoWorkspaceId ? 'main.js' : null,
        );
    if (!mounted) {
      return;
    }
    // Unsaved changes whose file changed meanwhile: the user picks.
    await resolveRestoredConflicts(context, ref);
  }

  void _onIntent(WorkbenchIntent intent) {
    if (!mounted) {
      return;
    }
    final documents = ref.read(documentControllerProvider.notifier);
    final active = ref.read(documentControllerProvider).activePath;
    switch (intent) {
      case WorkbenchIntent.newFile:
        unawaited(createNewFile(context, ref));
      case WorkbenchIntent.save:
        if (active != null) {
          unawaited(saveFile(context, ref, active));
        }
      case WorkbenchIntent.saveAs:
        if (active != null) {
          unawaited(saveFileAs(context, ref, active));
        }
      case WorkbenchIntent.closeEditor:
        if (active != null) {
          unawaited(closeFile(context, ref, active));
        }
      case WorkbenchIntent.closeOtherEditors:
        if (active != null) {
          unawaited(closeOtherFiles(context, ref, active));
        }
      case WorkbenchIntent.nextEditor:
        documents.activateNeighbour(forward: true);
      case WorkbenchIntent.previousEditor:
        documents.activateNeighbour(forward: false);
      case WorkbenchIntent.commandPalette:
        unawaited(showCommandPalette(context));
      case WorkbenchIntent.find:
      case WorkbenchIntent.replace:
        if (active != null) {
          unawaited(
            ref
                .read(findControllerProvider.notifier)
                .open(replace: intent == WorkbenchIntent.replace),
          );
        }
      case WorkbenchIntent.gotoLine:
        if (active != null) {
          unawaited(goToLine(context, ref));
        }
      case WorkbenchIntent.undo:
      case WorkbenchIntent.redo:
        if (active != null) {
          final command = intent == WorkbenchIntent.undo ? 'undo' : 'redo';
          unawaited(ref.read(editorHostProvider).exec(command));
        }
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
      // Android hands keys to Flutter before the focused WebView, so these
      // hold while the editor page has the focus too. The page forwards the
      // same keys (protocol app.shortcut) when one reaches it first.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(
            LogicalKeyboardKey.keyP,
            control: true,
            shift: true,
          ): () =>
              _onIntent(WorkbenchIntent.commandPalette),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
              _onIntent(WorkbenchIntent.save),
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            control: true,
            shift: true,
          ): () =>
              _onIntent(WorkbenchIntent.saveAs),
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
              _onIntent(WorkbenchIntent.newFile),
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
              _onIntent(WorkbenchIntent.closeEditor),
          const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
              _onIntent(WorkbenchIntent.nextEditor),
          const SingleActivator(
            LogicalKeyboardKey.tab,
            control: true,
            shift: true,
          ): () =>
              _onIntent(WorkbenchIntent.previousEditor),
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
              _onIntent(WorkbenchIntent.find),
          const SingleActivator(LogicalKeyboardKey.keyH, control: true): () =>
              _onIntent(WorkbenchIntent.replace),
          const SingleActivator(LogicalKeyboardKey.keyG, control: true): () =>
              _onIntent(WorkbenchIntent.gotoLine),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: compactPortrait
                  ? _CompactPortraitLayout(
                      shell: shell,
                      editorPaneKey: _editorPaneKey,
                      onToggleTerminal: _toggleTerminal,
                    )
                  : _DockedLayout(
                      shell: shell,
                      form: form,
                      editorPaneKey: _editorPaneKey,
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

// Terminal sizing must come from the height actually available to the body,
// never from the screen: while the soft keyboard is up the Scaffold shrinks
// its body (and strips the inset from the body's MediaQuery, so
// MediaQuery.viewInsets reads 0 here). Sizing from the screen let the
// terminal keep its full height and squeeze the editor until it overflowed —
// found by phase gate 42110297015, where Gboard opened during restore_a.

/// Height the compact layout always keeps for its chrome (top bar 49 + status
/// strip 24) plus a 191 dp editor floor. On an inset-free phone, where the
/// body is the screen minus the 56 dp activity bar, this reproduces the former
/// `screen − 320` terminal cap exactly.
const double _compactReserve = 264;

/// Height docked layouts keep for chrome and editor (the former cap, which
/// was already relative to the full-height body).
const double _dockedReserve = 320;

/// Below a header plus a sliver of output the terminal is hidden rather than
/// squeezed (its header alone is 49 dp).
const double _minTerminalHeight = 60;

/// Compact portrait: top bar, editor, optional terminal stop, status strip.
class _CompactPortraitLayout extends ConsumerWidget {
  const _CompactPortraitLayout({
    required this.shell,
    required this.editorPaneKey,
    required this.onToggleTerminal,
  });

  final ShellState shell;
  final GlobalKey editorPaneKey;
  final VoidCallback onToggleTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Stops keep their screen proportions; only the cap follows the body.
    final screenHeight = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxTerminal = (constraints.maxHeight - _compactReserve)
            .clamp(0.0, double.infinity)
            .toDouble();
        final wanted = switch (shell.terminalStop) {
          TerminalStop.closed => 0.0,
          TerminalStop.peek => 96.0,
          TerminalStop.half => screenHeight * 0.4,
          TerminalStop.full => screenHeight * 0.7,
        }.clamp(0.0, maxTerminal).toDouble();
        final terminalHeight = wanted >= _minTerminalHeight ? wanted : 0.0;
        return Column(
          children: [
            _WorkbenchTopBar(onToggleTerminal: onToggleTerminal),
            Expanded(child: EditorPane(key: editorPaneKey)),
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
      },
    );
  }
}

/// Landscape/tablet: rail + optional sidebar + editor + docked terminal.
class _DockedLayout extends ConsumerWidget {
  const _DockedLayout({
    required this.shell,
    required this.form,
    required this.editorPaneKey,
    required this.onActivitySelected,
    required this.onToggleTerminal,
  });

  final ShellState shell;
  final CfFormFactor form;
  final GlobalKey editorPaneKey;
  final ValueChanged<String> onActivitySelected;
  final VoidCallback onToggleTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showSidebar = form != CfFormFactor.compact;
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Keep editor space on short landscape surfaces and while the
              // soft keyboard is up; below the minimum the dock is hidden
              // entirely rather than overflowing.
              final maxTerminal = (constraints.maxHeight - _dockedReserve)
                  .clamp(0.0, double.infinity)
                  .toDouble();
              final terminalHeight = shell.terminalHeight
                  .clamp(0.0, maxTerminal)
                  .toDouble();
              final terminalOpen =
                  shell.terminalStop != TerminalStop.closed &&
                  terminalHeight >= _minTerminalHeight;
              return Column(
                children: [
                  _WorkbenchTopBar(onToggleTerminal: onToggleTerminal),
                  Expanded(child: EditorPane(key: editorPaneKey)),
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
              );
            },
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
              ref.watch(
                    workspaceControllerProvider.select(
                      (s) => s.workspace?.displayName,
                    ),
                  ) ??
                  'Workspace',
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
    final activeDoc = ref.watch(
      documentControllerProvider.select((s) => s.active),
    );
    return CfStatusStrip(
      children: [
        const CfStatusChip(
          key: ValueKey('status_branch'),
          icon: Icons.fork_right,
          label: 'main',
          tooltip: 'Git arrives in Phase 6',
        ),
        // The document's chips scroll rather than overflow on a narrow
        // phone at a large text scale.
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (activeDoc != null) ...[
                    CfStatusChip(
                      key: const ValueKey('status_language'),
                      label: activeDoc.language,
                      color: activeDoc.largeFile ? colors.warning : null,
                      tooltip: activeDoc.largeFile
                          ? 'Large file: opened as plain text'
                          : null,
                    ),
                    CfStatusChip(
                      key: const ValueKey('status_eol'),
                      label: activeDoc.format.lineEnding.label,
                      color: activeDoc.mixedLineEndings ? colors.warning : null,
                      tooltip: activeDoc.mixedLineEndings
                          ? 'Mixed line endings: saving writes '
                                '${activeDoc.format.lineEnding.label} '
                                'throughout'
                          : 'Line endings, kept on save',
                    ),
                    if (activeDoc.format.bom)
                      const CfStatusChip(
                        key: ValueKey('status_bom'),
                        label: 'BOM',
                        tooltip: 'UTF-8 with a byte-order mark, kept on save',
                      ),
                    if (activeDoc.dirty)
                      CfStatusChip(label: '●', color: colors.accentEmber),
                  ],
                ],
              ),
            ),
          ),
        ),
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
