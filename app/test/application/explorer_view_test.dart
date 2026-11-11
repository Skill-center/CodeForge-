/// The explorer's view (Phase 3 W3, gate G5): each workspace's expanded
/// folders and scroll, stored in the session store a moment after they
/// change, or at once when the app is backgrounded or another workspace
/// opens, and brought back for that workspace alone. Plain tests in real
/// time, over in-memory stores.
library;

import 'package:codeforge/application/explorer_view_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _folder = FolderLocation(
  treeUri: 'content://com.android.externalstorage.documents/tree/primary%3Acf',
  name: 'cf',
);

/// Lets the store's futures and the controller's microtasks run.
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _container(MemorySessionStore sessions) =>
    ProviderContainer.test(
      overrides: [
        shellStateStoreProvider.overrideWithValue(InMemoryShellStateStore()),
        sessionStoreProvider.overrideWithValue(sessions),
      ],
    );

void main() {
  test('a view is stored per workspace and comes back for it alone', () async {
    final sessions = MemorySessionStore();
    final container = _container(sessions);
    container.read(explorerViewProvider);
    await _drain();
    final view = container.read(explorerViewProvider.notifier);
    expect(container.read(explorerViewProvider).loaded, isTrue);
    expect(container.read(explorerViewProvider).expanded, {''});

    view
      ..toggle('src')
      ..toggle('src/lib')
      ..setScroll(240);
    expect(container.read(explorerViewProvider).expanded, {
      '',
      'src',
      'src/lib',
    });
    await view.flush();
    expect(sessions.views[demoWorkspaceId]?.expanded, {'src', 'src/lib'});
    expect(sessions.views[demoWorkspaceId]?.scrollOffset, 240);

    // Another workspace: its own view, and the demo's left as it was.
    await container.read(shellControllerProvider.notifier).setWorkspace(_folder);
    container.read(explorerViewProvider);
    await _drain();
    expect(container.read(explorerViewProvider).workspaceId, _folder.id);
    expect(container.read(explorerViewProvider).expanded, {''});
    container.read(explorerViewProvider.notifier).toggle('notes');

    // Back: what the folder had is stored on the way out, and the demo's
    // view comes back.
    await container
        .read(shellControllerProvider.notifier)
        .setWorkspace(const DemoProjectLocation());
    container.read(explorerViewProvider);
    await _drain();
    expect(sessions.views[_folder.id]?.expanded, {'notes'});
    final back = container.read(explorerViewProvider);
    expect(back.workspaceId, demoWorkspaceId);
    expect(back.expanded, {'', 'src', 'src/lib'});
    expect(back.restoreOffset, 240);
  });

  test('a stored view arrives on its own, after a restart', () async {
    final sessions = MemorySessionStore();
    await sessions.saveView(
      demoWorkspaceId,
      const ExplorerView(expanded: {'src', '../bad'}, scrollOffset: 64),
    );
    final container = _container(sessions);
    container.read(explorerViewProvider);
    await _drain();
    final state = container.read(explorerViewProvider);
    expect(state.loaded, isTrue);
    expect(state.expanded, {'', 'src'});
    expect(state.restoreOffset, 64);
  });

  test('changes are stored a moment later; nothing changed, nothing '
      'written', () async {
    final sessions = MemorySessionStore();
    final container = _container(sessions);
    final view = container.read(explorerViewProvider.notifier);
    await _drain();
    final before = sessions.writes;
    await view.flush();
    expect(sessions.writes, before);
    view.toggle('src');
    expect(sessions.views, isEmpty);
    await Future<void>.delayed(
      ExplorerViewController.saveDelay + const Duration(milliseconds: 100),
    );
    expect(sessions.views[demoWorkspaceId]?.expanded, {'src'});
    // Small moves of the scroll are not changes.
    final writes = sessions.writes;
    view.setScroll(0.5);
    await view.flush();
    expect(sessions.writes, writes);
  });
}
