/// The Source control panel (Phase 7 W4, PHASE_7_PLAN W4;
/// docs/GIT_ARCHITECTURE.md §3), where the open project's repository is
/// worked with:
///
/// - **The branch bar:** the branch, its upstream and how far ahead and
///   behind it is, with *Fetch*, *Pull* and *Push* — each with its
///   progress and *Stop*, as Home's clone has (clone_dialog.dart).
/// - **Changes:** conflicted, staged, unstaged and untracked files, each
///   with its letter and colour. A tap opens the file and shows what
///   changed in it (Phase 7 W5); a long press opens the file alone. The
///   buttons on the row stage it, unstage it, or discard it after a
///   confirmation that names it.
/// - **The commit box:** the message, *Amend the last commit*, and
///   *Commit*, which says why it cannot run rather than failing
///   ([commitProblem]): a conflict, nothing staged, no identity, no
///   message.
/// - **A merge that stopped on conflicts:** the conflicted files, each
///   opened with its markers and marked resolved when it is fixed, and
///   *Abort the merge*.
/// - **Branches:** the local ones with the current marked, a new branch
///   from the commit checked out, a switch (refused with git's reason
///   when changes would be lost), and a delete — forced only after a
///   second confirmation for a branch that is not merged.
/// - **History:** the branch's newest commits; a tap shows the commit's
///   files, and a tap on one of those opens it as that commit left it,
///   read-only, against the commit before it (Phase 7 W5).
///
/// A folder from shared storage has no Git (PHASE_7_PLAN §10, decision
/// (a)): the panel says so and offers *Import as project*, which copies
/// the folder's `.git` with everything else.
///
/// Reads for the branches and the history live in the panel controller
/// (application/git/git_panel_controller.dart); everything that changes
/// the repository goes through the Git controller, which queues it and
/// refreshes the status after it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../application/documents/document_controller.dart';
import '../../../application/git/git_controller.dart';
import '../../../application/git/git_diff_controller.dart';
import '../../../application/git/git_file_states.dart';
import '../../../application/git/git_panel_controller.dart';
import '../../../application/providers.dart';
import '../../../core/errors/failure.dart';
import '../../../core/files/workspace_location.dart';
import '../../../core/git/git_errors.dart';
import '../../../core/git/git_models.dart';
import '../../../core/platform/breakpoints.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/icons.dart';
import '../../git/git_dialogs.dart';
import '../../git/git_state_look.dart';
import '../../home/clone_dialog.dart' show showGitProgress;
import '../../home/import_folder.dart';
import '../file_actions.dart' show showFileMessage;
import '../file_dialogs.dart' show askToConfirm;

class GitPanel extends ConsumerStatefulWidget {
  const GitPanel({super.key, this.onFileOpened});

  /// Runs once a file opened (the phone's sheet closes to show it).
  final VoidCallback? onFileOpened;

  @override
  ConsumerState<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends ConsumerState<GitPanel> {
  late final TextEditingController _message;
  final FocusNode _messageFocus = FocusNode(debugLabel: 'commit message');

  @override
  void initState() {
    super.initState();
    // The panel comes and goes with the activity; the message stays.
    _message = TextEditingController(
      text: ref.read(gitPanelControllerProvider).message,
    );
  }

  @override
  void dispose() {
    _message.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  GitController get _git => ref.read(gitControllerProvider.notifier);

  GitPanelController get _panel =>
      ref.read(gitPanelControllerProvider.notifier);

  void _say(String message) {
    if (mounted) {
      showFileMessage(context, message);
    }
  }

  /// Runs [change] and says what went wrong; true when it worked.
  Future<bool> _run(Future<Result<void>> change) async {
    final result = await change;
    if (result case Err<void>(:final failure)) {
      _say(failure.message);
      return false;
    }
    return true;
  }

  Future<void> _open(String path) async {
    final opened = await ref
        .read(documentControllerProvider.notifier)
        .open(path);
    if (!mounted) {
      return;
    }
    if (opened case Err<void>(:final failure)) {
      _say(failure.message);
      return;
    }
    widget.onFileOpened?.call();
  }

  /// Opens [file] and shows what changed in it (Phase 7 W5). The file is
  /// open either way: a comparison that cannot be read is only said.
  Future<void> _openDiff(GitFileStatus file) async {
    final shown = await ref
        .read(gitDiffControllerProvider.notifier)
        .showChanges(file);
    if (!mounted) {
      return;
    }
    if (shown case Err<void>(:final failure)) {
      _say(failure.message);
      if (failure is FileFailure && failure.problem == FileProblem.notFound) {
        return;
      }
    }
    widget.onFileOpened?.call();
  }

  /// Opens [file] as [commit] left it, read-only, beside the comparison
  /// with the commit before it (Phase 7 W5). Two columns where the window
  /// is wide enough to read them.
  Future<void> _openCommitFile(GitCommit commit, GitCommitFile file) async {
    final width = MediaQuery.sizeOf(context).width;
    final shown = await ref
        .read(gitDiffControllerProvider.notifier)
        .showCommitFile(
          commit,
          file,
          // Two columns need a window wide enough to read them both.
          wide: formFactorFor(width) == CfFormFactor.expanded,
        );
    if (!mounted) {
      return;
    }
    if (shown case Err<void>(:final failure)) {
      _say(failure.message);
      return;
    }
    widget.onFileOpened?.call();
  }

  Future<void> _discard(GitFileStatus file) async {
    final words = discardWords(file);
    final confirmed = await askToConfirm(
      context,
      title: words.title,
      message: words.message,
      confirmLabel: words.confirmLabel,
    );
    if (!confirmed || !mounted) {
      return;
    }
    await _run(
      file.untracked
          ? _git.deleteUntracked([file.path])
          : _git.discard([file.path]),
    );
  }

  Future<void> _commit() async {
    final result = await _panel.commit();
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<void>():
        _message.clear();
        _say('Committed.');
      case Err<void>(:final failure):
        _say(failure.message);
    }
  }

  Future<void> _remote(String name) async {
    final title = switch (name) {
      'fetch' => 'Fetching',
      'pull' => 'Pulling',
      _ => 'Pushing',
    };
    final result = await showGitProgress(
      context,
      title: title,
      run: (onProgress, stop) => switch (name) {
        'fetch' => _git.fetch(onProgress: onProgress, stop: stop),
        'pull' => _git.pull(onProgress: onProgress, stop: stop),
        _ => _git.push(onProgress: onProgress, stop: stop),
      },
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<void>():
        _say(switch (name) {
          'fetch' => 'Fetched.',
          'pull' => 'Pulled.',
          _ => 'Pushed.',
        });
      case Err<void>(failure: GitFailure(problem: GitProblem.stopped)):
        _say('Stopped.');
      case Err<void>(:final failure):
        _say(failure.message);
    }
  }

  Future<void> _newBranch(GitBranchState branch) async {
    final name = await askNewBranch(
      context,
      from: branch.unborn ? 'the first commit' : branch.label,
      submit: (name) async {
        final valid = await ref
            .read(gitServiceProvider)
            .isValidBranchName(name);
        if (valid case Ok<bool>(value: false)) {
          return gitProblemMessage(GitProblem.invalidName);
        }
        final made = await _git.createBranch(name);
        if (made case Err<void>(:final failure)) {
          return failure.message;
        }
        return null;
      },
    );
    if (name != null) {
      _panel.reload();
    }
  }

  Future<void> _switchBranch(GitBranch branch) async {
    if (branch.current) {
      return;
    }
    if (await _run(_git.switchBranch(branch.name))) {
      _panel.reload();
    }
  }

  Future<void> _deleteBranch(GitBranch branch) async {
    final confirmed = await askToConfirm(
      context,
      title: 'Delete branch ${branch.name}?',
      message:
          'The branch goes; the commits on it stay until Git clears them. '
          'A branch that is not merged asks again.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) {
      return;
    }
    final deleted = await _git.deleteBranch(branch.name);
    if (!mounted) {
      return;
    }
    if (deleted case Err<void>(failure: final failure)) {
      if (failure is GitFailure &&
          failure.problem == GitProblem.notFullyMerged) {
        final force = await askToConfirm(
          context,
          title: 'Delete ${branch.name} anyway?',
          message:
              'It has commits that are on no other branch. Deleting it '
              'loses them.',
          confirmLabel: 'Delete anyway',
        );
        if (!force || !mounted) {
          return;
        }
        if (await _run(_git.deleteBranch(branch.name, force: true))) {
          _panel.reload();
        }
        return;
      }
      _say(failure.message);
      return;
    }
    _panel.reload();
  }

  Future<void> _abortMerge() async {
    final confirmed = await askToConfirm(
      context,
      title: 'Abort the merge?',
      message:
          'The merge is undone and the files go back to what they were '
          'before it started.',
      confirmLabel: 'Abort the merge',
    );
    if (!confirmed || !mounted) {
      return;
    }
    if (await _run(_git.abortMerge())) {
      _say('The merge was aborted.');
    }
  }

  Future<void> _showCommit(GitCommit commit) {
    return showCommitSheet(
      context,
      commit: commit,
      files: () => _panel.commitFiles(commit.hash),
      onFile: (file) => unawaited(_openCommitFile(commit, file)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final git = ref.watch(gitControllerProvider);
    final textTheme = Theme.of(context).textTheme;
    // The message is the controller's; the field follows it when a commit
    // or an amend changed it behind the panel's back.
    final message = ref.watch(
      gitPanelControllerProvider.select((panel) => panel.message),
    );
    if (message != _message.text) {
      _message.value = TextEditingValue(
        text: message,
        selection: TextSelection.collapsed(offset: message.length),
      );
    }
    return Column(
      key: const ValueKey('git_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CfSpacing.lg,
            CfSpacing.md,
            CfSpacing.sm,
            CfSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'SOURCE CONTROL',
                  style: textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (git.refreshing)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              CfIconButton(
                key: const ValueKey('git_refresh'),
                icon: CfIcons.replay,
                tooltip: 'Read the repository again',
                size: 16,
                onPressed: () => unawaited(_git.refresh()),
              ),
            ],
          ),
        ),
        Expanded(child: _body(git)),
      ],
    );
  }

  Widget _body(GitRepoState git) {
    switch (git.kind) {
      case GitRepoKind.unavailable:
        return const CfEmptyState(
          icon: CfIcons.commit,
          title: 'Source control',
          message:
              'Git runs in the bundled Linux runtime, which is not '
              'available here.',
        );
      case GitRepoKind.folder:
        return _folderState();
      case GitRepoKind.waiting:
        return const CfEmptyState(
          icon: CfIcons.commit,
          title: 'Waiting for the runtime',
          message:
              'Git starts as soon as the Linux runtime is ready. Settings, '
              'Runtime says how it is going.',
        );
      case GitRepoKind.loading:
        return const Center(
          key: ValueKey('git_loading'),
          child: CircularProgressIndicator(),
        );
      case GitRepoKind.notARepository:
        return CfEmptyState(
          key: const ValueKey('git_not_a_repository'),
          icon: CfIcons.commit,
          title: 'Not a repository yet',
          message:
              'Make this project a Git repository to stage and commit its '
              'files, or clone one from Home.',
          actionLabel: 'Make it a repository',
          onAction: () => unawaited(_initRepository()),
        );
      case GitRepoKind.repository:
      case GitRepoKind.failed:
        return _repository(git);
    }
  }

  Widget _folderState() {
    final location = ref.watch(currentWorkspaceProvider);
    return CfEmptyState(
      key: const ValueKey('git_folder_state'),
      icon: CfIcons.inventory2,
      title: 'Git works in projects',
      message:
          'This folder is open from shared storage, where Git cannot run. '
          'Importing it as a project copies everything, its .git folder '
          'included, and Git works there.',
      actionLabel: location is FolderLocation ? 'Import as project' : null,
      onAction: location is FolderLocation
          ? () => unawaited(
              importFolderAsProject(
                context,
                ref,
                location,
                tell: _say,
                opened: () => widget.onFileOpened?.call(),
              ),
            )
          : null,
    );
  }

  Future<void> _initRepository() async {
    if (await _run(_git.init())) {
      _say('The project is a Git repository now.');
    }
  }

  Widget _repository(GitRepoState git) {
    final panel = ref.watch(gitPanelControllerProvider);
    final status = git.status;
    final failure = git.failure;
    return CustomScrollView(
      key: const ValueKey('git_sections'),
      slivers: [
        if (failure != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                CfSpacing.lg,
                0,
                CfSpacing.lg,
                CfSpacing.sm,
              ),
              child: CfBanner(
                key: const ValueKey('git_failure'),
                message: failure.message,
                kind: CfBannerKind.warning,
                actionLabel: 'Try again',
                onAction: () => unawaited(_git.refresh()),
              ),
            ),
          ),
        if (status != null) SliverToBoxAdapter(child: _branchBar(status)),
        ..._changesSlivers(git, panel, status),
        ..._branchesSlivers(panel, status),
        ..._historySlivers(panel),
        const SliverToBoxAdapter(child: SizedBox(height: CfSpacing.xl)),
      ],
    );
  }

  Widget _branchBar(GitStatus status) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final branch = status.branch;
    final upstream = branch.upstream;
    final ahead = branch.ahead ?? 0;
    final behind = branch.behind ?? 0;
    final changing = ref.watch(
      gitControllerProvider.select((git) => git.changing),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CfSpacing.lg,
        0,
        CfSpacing.lg,
        CfSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(CfIcons.forkRight, size: 16, color: colors.textSecondary),
              const SizedBox(width: CfSpacing.sm),
              Expanded(
                child: Text(
                  key: const ValueKey('git_branch_name_label'),
                  branch.detached
                      ? 'Detached at ${branch.label}'
                      : branch.label,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            key: const ValueKey('git_upstream'),
            upstream == null
                ? (branch.unborn
                      ? 'No commits yet.'
                      : 'No upstream: Push sets one.')
                : '$upstream · $ahead ahead, $behind behind',
            style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: CfSpacing.sm),
          Wrap(
            spacing: CfSpacing.sm,
            runSpacing: CfSpacing.sm,
            children: [
              CfButton(
                key: const ValueKey('git_fetch'),
                label: 'Fetch',
                variant: CfButtonVariant.ghost,
                onPressed: changing ? null : () => unawaited(_remote('fetch')),
              ),
              CfButton(
                key: const ValueKey('git_pull'),
                label: 'Pull',
                variant: CfButtonVariant.ghost,
                onPressed: changing ? null : () => unawaited(_remote('pull')),
              ),
              CfButton(
                key: const ValueKey('git_push'),
                label: 'Push',
                variant: CfButtonVariant.ghost,
                onPressed: changing ? null : () => unawaited(_remote('push')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// A section's header: its title, how many it holds, and the chevron.
  Widget _sectionHeader(
    GitPanelSection section, {
    required bool open,
    int? count,
    List<Widget> actions = const [],
  }) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: ValueKey('git_section_${section.name}'),
      onTap: () => _panel.toggle(section),
      child: Container(
        constraints: const BoxConstraints(minHeight: CfSpacing.minTouchTarget),
        padding: const EdgeInsets.only(left: CfSpacing.sm),
        child: Row(
          children: [
            Semantics(
              label: open ? 'Close' : 'Open',
              excludeSemantics: true,
              child: Icon(
                open ? CfIcons.expandMore : CfIcons.chevronRight,
                size: 16,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: CfSpacing.xs),
            Expanded(
              child: Text(
                count == null
                    ? section.title.toUpperCase()
                    : '${section.title.toUpperCase()}  $count',
                style: textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }

  List<Widget> _changesSlivers(
    GitRepoState git,
    GitPanelState panel,
    GitStatus? status,
  ) {
    final open = panel.isOpen(GitPanelSection.changes);
    final files = status?.files ?? const <GitFileStatus>[];
    final conflicted = status?.conflicted ?? const <GitFileStatus>[];
    final staged = status?.staged ?? const <GitFileStatus>[];
    final unstaged = status?.unstaged ?? const <GitFileStatus>[];
    final untracked = status?.untracked ?? const <GitFileStatus>[];
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _sectionHeader(
          GitPanelSection.changes,
          open: open,
          count: status?.changeCount,
          actions: [
            if (open && (unstaged.isNotEmpty || untracked.isNotEmpty))
              CfIconButton(
                key: const ValueKey('git_stage_all'),
                icon: CfIcons.doneAll,
                tooltip: 'Stage every change',
                size: 16,
                onPressed: () => unawaited(_run(_git.stageAll())),
              ),
            if (open && staged.isNotEmpty)
              CfIconButton(
                key: const ValueKey('git_unstage_all'),
                icon: CfIcons.playlistRemove,
                tooltip: 'Unstage everything',
                size: 16,
                onPressed: () => unawaited(
                  _run(_git.unstage([for (final file in staged) file.path])),
                ),
              ),
          ],
        ),
      ),
    ];
    if (!open) {
      return slivers;
    }
    if (status != null && status.truncated) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
            child: Text(
              key: const ValueKey('git_truncated'),
              'This is the first ${files.length} changed files; there are '
              'more.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      );
    }
    if (conflicted.isNotEmpty) {
      slivers
        ..add(
          SliverToBoxAdapter(
            child: _groupHeader(
              'Conflicts',
              conflicted.length,
              trailing: CfIconButton(
                key: const ValueKey('git_abort_merge'),
                icon: CfIcons.close,
                tooltip: 'Abort the merge',
                size: 16,
                onPressed: () => unawaited(_abortMerge()),
              ),
            ),
          ),
        )
        ..add(_fileList(conflicted, _GitFileGroup.conflicted));
    }
    if (staged.isNotEmpty) {
      slivers
        ..add(SliverToBoxAdapter(child: _groupHeader('Staged', staged.length)))
        ..add(_fileList(staged, _GitFileGroup.staged));
    }
    if (unstaged.isNotEmpty) {
      slivers
        ..add(
          SliverToBoxAdapter(child: _groupHeader('Changes', unstaged.length)),
        )
        ..add(_fileList(unstaged, _GitFileGroup.unstaged));
    }
    if (untracked.isNotEmpty) {
      slivers
        ..add(
          SliverToBoxAdapter(
            child: _groupHeader('New files', untracked.length),
          ),
        )
        ..add(_fileList(untracked, _GitFileGroup.untracked));
    }
    if (files.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              CfSpacing.lg,
              CfSpacing.xs,
              CfSpacing.lg,
              CfSpacing.sm,
            ),
            child: Text(
              key: const ValueKey('git_no_changes'),
              'Nothing has changed since the last commit.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      );
    }
    slivers.add(SliverToBoxAdapter(child: _commitBox(git, panel)));
    return slivers;
  }

  Widget _groupHeader(String title, int count, {Widget? trailing}) {
    final textTheme = Theme.of(context).textTheme;
    final colors = CfColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CfSpacing.lg,
        CfSpacing.sm,
        CfSpacing.sm,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$title ($count)',
              style: textTheme.labelMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _fileList(List<GitFileStatus> files, _GitFileGroup group) {
    return SliverList.builder(
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        return _GitFileRow(
          file: file,
          group: group,
          onOpen: () => unawaited(_openDiff(file)),
          onOpenFile: () => unawaited(_open(file.path)),
          onStage: () => unawaited(_run(_git.stage([file.path]))),
          onUnstage: () => unawaited(_run(_git.unstage([file.path]))),
          onDiscard: () => unawaited(_discard(file)),
        );
      },
    );
  }

  Widget _commitBox(GitRepoState git, GitPanelState panel) {
    final problem = commitProblem(git, panel);
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CfSpacing.lg,
        CfSpacing.md,
        CfSpacing.lg,
        CfSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('git_commit_message'),
            controller: _message,
            focusNode: _messageFocus,
            minLines: 2,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              labelText: 'Message',
              hintText: 'What this commit does',
            ),
            onChanged: _panel.setMessage,
          ),
          const SizedBox(height: CfSpacing.xs),
          MergeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Amend the last commit',
                    style: textTheme.bodySmall,
                  ),
                ),
                Switch(
                  key: const ValueKey('git_amend'),
                  value: panel.amend,
                  onChanged: (on) => unawaited(_panel.setAmend(on)),
                ),
              ],
            ),
          ),
          CfButton(
            key: const ValueKey('git_commit'),
            label: panel.amend ? 'Amend' : 'Commit',
            icon: CfIcons.commit,
            expanded: true,
            onPressed: problem == null ? () => unawaited(_commit()) : null,
          ),
          if (problem != null) ...[
            const SizedBox(height: CfSpacing.xs),
            Text(
              problem,
              key: const ValueKey('git_commit_problem'),
              style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _branchesSlivers(GitPanelState panel, GitStatus? status) {
    final open = panel.isOpen(GitPanelSection.branches);
    final branches = panel.localBranches;
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _sectionHeader(
          GitPanelSection.branches,
          open: open,
          count: open && panel.loaded.contains(GitPanelSection.branches)
              ? branches.length
              : null,
          actions: [
            if (open && status != null)
              CfIconButton(
                key: const ValueKey('git_new_branch'),
                icon: CfIcons.add,
                tooltip: 'New branch',
                size: 16,
                onPressed: () => unawaited(_newBranch(status.branch)),
              ),
          ],
        ),
      ),
    ];
    if (!open) {
      return slivers;
    }
    final failure = panel.failures[GitPanelSection.branches];
    if (panel.isLoading(GitPanelSection.branches) && branches.isEmpty) {
      slivers.add(const SliverToBoxAdapter(child: _SectionProgress()));
      return slivers;
    }
    if (failure != null) {
      slivers.add(
        SliverToBoxAdapter(
          child: _SectionMessage(
            key: const ValueKey('git_branches_problem'),
            message: failure.message,
          ),
        ),
      );
      return slivers;
    }
    if (branches.isEmpty) {
      slivers.add(
        const SliverToBoxAdapter(
          child: _SectionMessage(
            key: ValueKey('git_no_branches'),
            message: 'No branches yet: the first commit makes one.',
          ),
        ),
      );
      return slivers;
    }
    slivers.add(
      SliverList.builder(
        itemCount: branches.length,
        itemBuilder: (context, index) {
          final branch = branches[index];
          return _GitBranchRow(
            branch: branch,
            onSwitch: () => unawaited(_switchBranch(branch)),
            onDelete: branch.current
                ? null
                : () => unawaited(_deleteBranch(branch)),
          );
        },
      ),
    );
    return slivers;
  }

  List<Widget> _historySlivers(GitPanelState panel) {
    final open = panel.isOpen(GitPanelSection.history);
    final history = panel.history;
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _sectionHeader(GitPanelSection.history, open: open),
      ),
    ];
    if (!open) {
      return slivers;
    }
    final failure = panel.failures[GitPanelSection.history];
    if (panel.isLoading(GitPanelSection.history) && history.isEmpty) {
      slivers.add(const SliverToBoxAdapter(child: _SectionProgress()));
      return slivers;
    }
    if (failure != null) {
      slivers.add(
        SliverToBoxAdapter(
          child: _SectionMessage(
            key: const ValueKey('git_history_problem'),
            message: failure.message,
          ),
        ),
      );
      return slivers;
    }
    if (history.isEmpty) {
      slivers.add(
        const SliverToBoxAdapter(
          child: _SectionMessage(
            key: ValueKey('git_no_history'),
            message: 'No commits on this branch yet.',
          ),
        ),
      );
      return slivers;
    }
    slivers.add(
      SliverList.builder(
        itemCount: history.length,
        itemBuilder: (context, index) {
          final commit = history[index];
          return _GitCommitRow(
            commit: commit,
            onTap: () => unawaited(_showCommit(commit)),
          );
        },
      ),
    );
    return slivers;
  }
}

/// Which list a row belongs to: it decides the row's buttons.
enum _GitFileGroup { conflicted, staged, unstaged, untracked }

class _GitFileRow extends StatelessWidget {
  const _GitFileRow({
    required this.file,
    required this.group,
    required this.onOpen,
    required this.onOpenFile,
    required this.onStage,
    required this.onUnstage,
    required this.onDiscard,
  });

  final GitFileStatus file;
  final _GitFileGroup group;

  /// A tap: the file, with what changed in it (Phase 7 W5).
  final VoidCallback onOpen;

  /// A long press: the file by itself.
  final VoidCallback onOpenFile;
  final VoidCallback onStage;
  final VoidCallback onUnstage;
  final VoidCallback onDiscard;

  /// The letter the row shows: the side of the change this group is about.
  String get _letter {
    if (file.conflicted) {
      return file.conflict?.code ?? 'UU';
    }
    if (file.untracked) {
      return 'U';
    }
    final change = group == _GitFileGroup.staged ? file.index : file.workTree;
    return change.letter;
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final state = gitFileStateOf(file) ?? GitFileState.modified;
    final color = gitStateColor(state, colors);
    final slash = file.path.lastIndexOf('/');
    final name = slash < 0 ? file.path : file.path.substring(slash + 1);
    final folder = slash < 0 ? null : file.path.substring(0, slash);
    // The row's own node reads the name, where it is and how it stands;
    // the buttons keep their own nodes, with their tooltips.
    return InkWell(
      key: ValueKey('git_file_${file.path}'),
      onTap: onOpen,
      onLongPress: onOpenFile,
      child: Container(
        constraints: const BoxConstraints(minHeight: CfSpacing.minTouchTarget),
        padding: const EdgeInsets.only(left: CfSpacing.lg),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        fontSize: 13,
                        color: colors.textPrimary,
                        decoration: state == GitFileState.deleted
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                  if (folder != null) ...[
                    const SizedBox(width: CfSpacing.xs),
                    Flexible(
                      child: Text(
                        folder,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.textDisabled,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: CfSpacing.xs),
            Semantics(
              label: state.word,
              excludeSemantics: true,
              child: Text(
                _letter,
                style: textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (group == _GitFileGroup.conflicted)
              CfIconButton(
                key: ValueKey('git_resolve_${file.path}'),
                icon: CfIcons.check,
                tooltip: 'Mark ${file.path} resolved',
                size: 16,
                onPressed: onStage,
              )
            else if (group == _GitFileGroup.staged)
              CfIconButton(
                key: ValueKey('git_unstage_${file.path}'),
                icon: CfIcons.backspace,
                tooltip: 'Unstage ${file.path}',
                size: 16,
                onPressed: onUnstage,
              )
            else ...[
              CfIconButton(
                key: ValueKey('git_discard_${file.path}'),
                icon: CfIcons.undo,
                tooltip: file.untracked
                    ? 'Delete ${file.path}'
                    : 'Discard the changes to ${file.path}',
                size: 16,
                onPressed: onDiscard,
              ),
              CfIconButton(
                key: ValueKey('git_stage_${file.path}'),
                icon: CfIcons.add,
                tooltip: 'Stage ${file.path}',
                size: 16,
                onPressed: onStage,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GitBranchRow extends StatelessWidget {
  const _GitBranchRow({
    required this.branch,
    required this.onSwitch,
    this.onDelete,
  });

  final GitBranch branch;
  final VoidCallback onSwitch;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final tracking = branch.upstreamGone
        ? 'its upstream is gone'
        : branch.upstream == null
        ? 'no upstream'
        : '${branch.upstream} · ${branch.ahead} ahead, ${branch.behind} behind';
    return InkWell(
      key: ValueKey('git_branch_${branch.name}'),
      onTap: branch.current ? null : onSwitch,
      child: Container(
        constraints: const BoxConstraints(minHeight: CfSpacing.minTouchTarget),
        padding: const EdgeInsets.only(left: CfSpacing.lg),
        child: Row(
          children: [
            Semantics(
              label: branch.current ? 'The branch checked out' : 'Switch to',
              excludeSemantics: true,
              child: Icon(
                branch.current ? CfIcons.check : CfIcons.forkRight,
                size: 16,
                color: branch.current
                    ? colors.accentEmber
                    : colors.textSecondary,
              ),
            ),
            const SizedBox(width: CfSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    branch.name,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(fontSize: 13),
                  ),
                  Text(
                    tracking,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.textDisabled,
                    ),
                  ),
                ],
              ),
            ),
            if (onDelete != null)
              CfIconButton(
                key: ValueKey('git_delete_branch_${branch.name}'),
                icon: CfIcons.delete,
                tooltip: 'Delete ${branch.name}',
                size: 16,
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}

class _GitCommitRow extends StatelessWidget {
  const _GitCommitRow({required this.commit, required this.onTap});

  final GitCommit commit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: ValueKey('git_commit_${commit.shortHash}'),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: CfSpacing.minTouchTarget),
        padding: const EdgeInsets.symmetric(
          horizontal: CfSpacing.lg,
          vertical: CfSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              commit.subject.isEmpty ? '(no message)' : commit.subject,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium?.copyWith(fontSize: 13),
            ),
            Text(
              '${commit.shortHash} · ${commit.authorName} · '
              '${describeCommitDate(commit.authoredAt)}'
              '${commit.merge ? ' · merge' : ''}',
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: colors.textDisabled),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionProgress extends StatelessWidget {
  const _SectionProgress();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(CfSpacing.lg),
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _SectionMessage extends StatelessWidget {
  const _SectionMessage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CfSpacing.lg,
        CfSpacing.xs,
        CfSpacing.lg,
        CfSpacing.sm,
      ),
      child: Text(message, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
