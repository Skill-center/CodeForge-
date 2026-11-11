/// Home: the launcher (Phase 3 W3). New projects, a folder from the device
/// through Android's folder picker (W2), the demo project, and the recents:
/// every project and folder opened before, with its kind, its place and
/// whether it is still there. Projects are renamed and deleted here;
/// folders are reconnected, or removed from the recents.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/recents_controller.dart';
import '../../application/settings_controller.dart';
import '../../application/shell_controller.dart';
import '../../application/workspace_switcher.dart';
import '../../core/errors/failure.dart';
import '../../core/files/workspace_location.dart';
import '../../core/logging/logger.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../services/contracts.dart';
import '../../services/files/storage_broker.dart';
import 'home_dialogs.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

/// What can be done with an entry of the recents.
enum _RecentAction { open, rename, delete, reconnect, remove }

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// A workspace is opening (the picker may be up): the buttons wait.
  bool _busy = false;

  WorkspaceSwitcher get _switcher => ref.read(workspaceSwitcherProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(shellControllerProvider.notifier).setLastRoute('/');
      unawaited(_refresh());
      final settings = ref.read(settingsControllerProvider);
      if (!settings.welcomeSeen) {
        _showWelcome();
      }
    });
  }

  Future<void> _refresh() => ref.read(recentsProvider.notifier).refresh();

  void _showWelcome() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _WelcomeSheet(),
    );
  }

  Future<void> _openDemo() async {
    // The first time, this writes the demo project to the device.
    final result = await _whileBusy(
      () => _switcher.open(const DemoProjectLocation()),
    );
    if (!mounted || result == null) {
      return;
    }
    switch (result) {
      case Ok<WorkspaceRef>():
        ref.read(shellControllerProvider.notifier).markDemoWorkspaceOpened();
        appLogger.info('home', 'demo_workspace_opened');
        context.go('/workspace');
      case Err<WorkspaceRef>(:final failure):
        _tell(failure.message);
    }
  }

  /// Android's folder picker; the folder picked opens as the workspace.
  Future<void> _openFolder() async {
    final result = await _whileBusy(_switcher.pickFolder);
    if (!mounted || result == null) {
      return;
    }
    switch (result) {
      case Ok<WorkspaceRef?>(:final value):
        if (value != null) {
          appLogger.info('home', 'folder_opened');
          context.go('/workspace');
        }
      case Err<WorkspaceRef?>(:final failure):
        _tell(failure.message);
    }
  }

  /// Creates a project, empty or from the demo project, and opens it.
  Future<void> _newProject() async {
    if (_busy) {
      return;
    }
    final asked = await askNewProject(
      context,
      taken: ref.read(recentsProvider).projectFolders,
    );
    if (!mounted || asked == null) {
      return;
    }
    final result = await _whileBusy<Result<WorkspaceRef>>(() async {
      final created = await _switcher.createProject(
        asked.name,
        fromTemplate: asked.fromTemplate,
      );
      switch (created) {
        case Ok<ProjectLocation>(:final value):
          return _switcher.open(value);
        case Err<ProjectLocation>(:final failure):
          return Err(failure);
      }
    });
    if (!mounted || result == null) {
      return;
    }
    switch (result) {
      case Ok<WorkspaceRef>():
        appLogger.info('home', 'project_opened');
        context.go('/workspace');
      case Err<WorkspaceRef>(:final failure):
        _tell(failure.message);
        unawaited(_refresh());
    }
  }

  /// An entry of the recents; one that is gone or no longer granted says
  /// so, and a folder offers to reconnect.
  Future<void> _open(RecentWorkspace entry) async {
    final result = await _whileBusy(() => _switcher.open(entry.location));
    if (!mounted || result == null) {
      return;
    }
    switch (result) {
      case Ok<WorkspaceRef>():
        context.go('/workspace');
      case Err<WorkspaceRef>(:final failure):
        final location = entry.location;
        _tell(
          failure.message,
          action: location is FolderLocation
              ? SnackBarAction(
                  label: 'Reconnect',
                  onPressed: () => unawaited(_reconnect(location)),
                )
              : null,
        );
        unawaited(_refresh());
    }
  }

  Future<void> _rename(ProjectLocation project) async {
    final name = await askProjectName(
      context,
      current: project.folder,
      taken: ref.read(recentsProvider).projectFolders,
    );
    if (!mounted || name == null) {
      return;
    }
    final result = await _whileBusy(
      () => _switcher.renameProject(project, name),
    );
    if (!mounted || result == null) {
      return;
    }
    if (result case Err<ProjectLocation>(:final failure)) {
      _tell(failure.message);
    }
    unawaited(_refresh());
  }

  Future<void> _delete(ProjectLocation project) async {
    final contents = await _whileBusy(
      () => _switcher.projectContents(project),
    );
    if (!mounted || contents == null) {
      return;
    }
    final unsaved = contents.unsaved == 0
        ? ''
        : ' Unsaved changes in ${countOf(contents.unsaved, 'file')} are '
              'discarded too.';
    final confirmed = await askHomeConfirm(
      context,
      title: 'Delete "${project.name}"?',
      message:
          'This deletes ${countOf(contents.files, 'file')} from this '
          'device, and it cannot be undone.$unsaved',
      confirmLabel: 'Delete',
    );
    if (!mounted || !confirmed) {
      return;
    }
    final result = await _whileBusy(() => _switcher.deleteProject(project));
    if (!mounted || result == null) {
      return;
    }
    if (result case Err<void>(:final failure)) {
      _tell(failure.message);
    }
    unawaited(_refresh());
  }

  Future<void> _remove(FolderLocation folder) async {
    final unsavedCount = await _whileBusy(() => _switcher.unsavedCount(folder));
    if (!mounted || unsavedCount == null) {
      return;
    }
    final unsaved = unsavedCount == 0
        ? ''
        : ' Unsaved changes in ${countOf(unsavedCount, 'file')} are '
              'discarded.';
    final confirmed = await askHomeConfirm(
      context,
      title: 'Remove "${folder.name}" from recents?',
      message:
          'CodeForge gives back its access to the folder. The folder and '
          'its files stay on the device.$unsaved',
      confirmLabel: 'Remove',
    );
    if (!mounted || !confirmed) {
      return;
    }
    final result = await _whileBusy(() => _switcher.removeFolder(folder));
    if (!mounted || result == null) {
      return;
    }
    if (result case Err<void>(:final failure)) {
      _tell(failure.message);
    }
    unawaited(_refresh());
  }

  /// The picker at the folder's old place. The folder itself reconnects;
  /// another one replaces the entry once the user agrees.
  Future<void> _reconnect(FolderLocation folder) async {
    final picked = await _whileBusy(() => _switcher.pickForReconnect(folder));
    if (!mounted || picked == null) {
      return;
    }
    final FolderInfo info;
    switch (picked) {
      case Err<FolderInfo?>(:final failure):
        _tell(failure.message);
        return;
      case Ok<FolderInfo?>(:final value):
        if (value == null) {
          return;
        }
        info = value;
    }
    if (!_switcher.isSameFolder(folder, info)) {
      final pickedName = info.name.isEmpty ? 'that folder' : '"${info.name}"';
      final replace = await askHomeConfirm(
        context,
        title: 'Replace "${folder.name}"?',
        message:
            'You picked $pickedName, not "${folder.name}". Its entry, tabs '
            'and unsaved changes move to the folder you picked.',
        confirmLabel: 'Replace',
      );
      if (!mounted) {
        return;
      }
      if (!replace) {
        await _switcher.dropPicked(info);
        return;
      }
    }
    final result = await _whileBusy(() => _switcher.reconnect(folder, info));
    if (!mounted || result == null) {
      return;
    }
    switch (result) {
      case Ok<WorkspaceRef>():
        appLogger.info('home', 'folder_reconnected');
        context.go('/workspace');
      case Err<WorkspaceRef>(:final failure):
        _tell(failure.message);
        unawaited(_refresh());
    }
  }

  Future<void> _showActions(RecentWorkspace entry) async {
    final location = entry.location;
    final action = await showModalBottomSheet<_RecentAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('recent_open'),
              leading: const Icon(Icons.arrow_forward),
              title: Text('Open ${location.name}'),
              onTap: () => Navigator.of(context).pop(_RecentAction.open),
            ),
            if (location is ProjectLocation && !location.isDemo)
              ListTile(
                key: const ValueKey('recent_rename'),
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('Rename…'),
                onTap: () => Navigator.of(context).pop(_RecentAction.rename),
              ),
            if (location is ProjectLocation)
              ListTile(
                key: const ValueKey('recent_delete'),
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete…'),
                onTap: () => Navigator.of(context).pop(_RecentAction.delete),
              ),
            if (location is FolderLocation) ...[
              ListTile(
                key: const ValueKey('recent_reconnect'),
                leading: const Icon(Icons.link),
                title: const Text('Reconnect…'),
                onTap: () =>
                    Navigator.of(context).pop(_RecentAction.reconnect),
              ),
              ListTile(
                key: const ValueKey('recent_remove'),
                leading: const Icon(Icons.playlist_remove),
                title: const Text('Remove from recents…'),
                onTap: () => Navigator.of(context).pop(_RecentAction.remove),
              ),
            ],
          ],
        ),
      ),
    );
    if (!mounted || action == null) {
      return;
    }
    switch ((action, location)) {
      case (_RecentAction.open, _):
        await _open(entry);
      case (_RecentAction.rename, final ProjectLocation project):
        await _rename(project);
      case (_RecentAction.delete, final ProjectLocation project):
        await _delete(project);
      case (_RecentAction.reconnect, final FolderLocation folder):
        await _reconnect(folder);
      case (_RecentAction.remove, final FolderLocation folder):
        await _remove(folder);
      default:
        break;
    }
  }

  /// Runs [work] unless other work is running (then null).
  Future<T?> _whileBusy<T>(Future<T> Function() work) async {
    if (_busy) {
      return null;
    }
    setState(() => _busy = true);
    try {
      return await work();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _tell(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message), action: action));
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final shell = ref.watch(shellControllerProvider);
    final recents = ref.watch(recentsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.hardware, size: 20, color: colors.accentEmber),
            const SizedBox(width: CfSpacing.sm),
            const Text('CodeForge'),
          ],
        ),
        actions: [
          CfIconButton(
            key: const ValueKey('home_settings'),
            icon: Icons.settings_outlined,
            tooltip: 'Settings',
            onPressed: () => context.go('/settings'),
          ),
          const SizedBox(width: CfSpacing.sm),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(CfSpacing.lg),
          children: [
            const SizedBox(height: CfSpacing.lg),
            Text('Forge code,\nanywhere.', style: textTheme.displaySmall),
            const SizedBox(height: CfSpacing.sm),
            Text(
              'A mobile-first development environment. Projects live on '
              'this device; folders come from its storage. The runtime and '
              'the terminal follow.',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: CfSpacing.xl),
            _Panel(
              children: [
                CfButton(
                  key: const ValueKey('new_project'),
                  label: 'New Project',
                  icon: Icons.add,
                  expanded: true,
                  onPressed: _busy ? null : _newProject,
                ),
                const SizedBox(height: CfSpacing.sm),
                CfButton(
                  key: const ValueKey('open_folder'),
                  label: 'Open Folder…',
                  icon: Icons.folder_open_outlined,
                  variant: CfButtonVariant.ghost,
                  expanded: true,
                  onPressed: _busy ? null : _openFolder,
                ),
                const SizedBox(height: CfSpacing.xs),
                Text(
                  'A folder on this device, picked in Android\'s folder '
                  'picker: CodeForge can reach that folder and nothing '
                  'else.',
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: CfSpacing.lg),
            _Panel(
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 18,
                      color: colors.accentEmber,
                    ),
                    const SizedBox(width: CfSpacing.sm),
                    Expanded(
                      child: Text(
                        demoProjectName,
                        style: textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: CfSpacing.sm),
                Text(
                  'A sample project — JavaScript, Python, Dart — kept on '
                  'this device. Open files in tabs, edit them and save.',
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: CfSpacing.lg),
                CfButton(
                  key: const ValueKey('explore_demo'),
                  label: shell.demoWorkspaceOpened
                      ? 'Continue in Demo Workspace'
                      : 'Explore Demo Workspace',
                  icon: Icons.arrow_forward,
                  variant: CfButtonVariant.tonal,
                  expanded: true,
                  onPressed: _busy ? null : _openDemo,
                ),
              ],
            ),
            const SizedBox(height: CfSpacing.xl),
            Text(
              'RECENT',
              style: textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: CfSpacing.sm),
            if (!recents.loaded)
              const SizedBox(height: CfSpacing.minTouchTarget)
            else if (recents.entries.isEmpty)
              Text(
                'Projects and folders you open appear here.',
                key: const ValueKey('recents_empty'),
                style: textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                ),
              )
            else
              _Panel(
                key: const ValueKey('recents'),
                padding: EdgeInsets.zero,
                children: [
                  for (final entry in recents.entries)
                    _RecentRow(
                      key: ValueKey('recent_${entry.location.id}'),
                      entry: entry,
                      enabled: !_busy,
                      onOpen: () => unawaited(_open(entry)),
                      onActions: () => unawaited(_showActions(entry)),
                    ),
                ],
              ),
            const SizedBox(height: CfSpacing.lg),
            const CfBanner(
              message:
                  'Editing, projects and folders are real. The terminal '
                  'and runtimes arrive in later phases, and their panels '
                  'say so.',
            ),
          ],
        ),
      ),
    );
  }
}

/// A raised panel holding [children] in a column.
class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(CfSpacing.lg),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.surfacePanel,
        borderRadius: BorderRadius.circular(CfRadius.md),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// One entry of the recents: its name, kind and place, what was found when
/// it was checked, and its actions.
class _RecentRow extends StatelessWidget {
  const _RecentRow({
    super.key,
    required this.entry,
    required this.enabled,
    required this.onOpen,
    required this.onActions,
  });

  final RecentWorkspace entry;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final location = entry.location;
    final isProject = location is ProjectLocation;
    final (statusLabel, statusColor) = switch (entry.status) {
      WorkspaceStatus.available => ('available', colors.textSecondary),
      WorkspaceStatus.missing => (
        isProject ? 'missing' : 'folder missing',
        colors.warning,
      ),
      WorkspaceStatus.accessLost => ('access lost', colors.warning),
      WorkspaceStatus.checking || WorkspaceStatus.unknown => ('', null),
    };
    return InkWell(
      onTap: enabled ? onOpen : null,
      borderRadius: BorderRadius.circular(CfRadius.md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: CfSpacing.minTouchTarget),
        child: Padding(
          padding: const EdgeInsets.only(
            left: CfSpacing.lg,
            top: CfSpacing.sm,
            bottom: CfSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                isProject ? Icons.inventory_2_outlined : Icons.folder_outlined,
                size: 20,
                color: colors.accentEmber,
              ),
              const SizedBox(width: CfSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      location.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall,
                    ),
                    Text(
                      '${isProject ? 'Project' : 'Folder'} · '
                      '${entry.displayPath}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (statusLabel.isNotEmpty)
                CfStatusChip(
                  key: ValueKey('recent_status_${location.id}'),
                  label: statusLabel,
                  color: statusColor,
                ),
              CfIconButton(
                key: ValueKey('recent_menu_${location.id}'),
                icon: Icons.more_vert,
                tooltip: 'Actions for ${location.name}',
                onPressed: enabled ? onActions : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeSheet extends ConsumerWidget {
  const _WelcomeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    // Scrollable so large text scales never overflow on short landscape
    // screens (G3); the sheet still sizes to its content.
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(CfSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hardware, size: 24, color: colors.accentEmber),
                const SizedBox(width: CfSpacing.sm),
                Text('Welcome to CodeForge', style: textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: CfSpacing.lg),
            Text('What you can do today:', style: textTheme.bodyMedium),
            const SizedBox(height: CfSpacing.md),
            Text(
              '•  Create projects, or open a folder from this device\n'
              '•  Edit and save real files, with tabs, find and replace\n'
              '•  Switch themes, fonts and motion in Settings\n'
              '•  Your layout, open tabs and unsaved text come back after a '
              'restart',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: CfSpacing.lg),
            CfButton(
              key: const ValueKey('welcome_dismiss'),
              label: 'Start forging',
              expanded: true,
              onPressed: () {
                ref.read(settingsControllerProvider.notifier).setWelcomeSeen();
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}
