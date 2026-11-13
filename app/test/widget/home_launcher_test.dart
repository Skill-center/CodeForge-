/// Home as the launcher (Phase 3 W3, gate G2): New Project, the recents
/// with each workspace's kind, place and status, and each entry's menu:
/// Rename and Delete for projects, Reconnect and Remove from recents for
/// folders. Over in-memory stores, in-memory project folders and a fake
/// storage broker.
library;

import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_storage_broker.dart';
import '../support/memory_project_storage.dart';
import 'test_harness.dart';

const _here =
    'content://com.android.externalstorage.documents/tree/primary%3Ahere';
const _lost =
    'content://com.android.externalstorage.documents/tree/primary%3Alost';
const _moved =
    'content://com.android.externalstorage.documents/tree/primary%3Amoved';

const _alpha = ProjectLocation(id: 'project-a', name: 'alpha', folder: 'alpha');
const _gone = ProjectLocation(id: 'project-g', name: 'gone', folder: 'gone');
const _hereFolder = FolderLocation(treeUri: _here, name: 'here');
const _lostFolder = FolderLocation(treeUri: _lost, name: 'lost');

/// A session store that has recorded [workspaces], oldest first.
Future<MemorySessionStore> _recorded(List<WorkspaceLocation> workspaces) async {
  final sessions = MemorySessionStore();
  for (final workspace in workspaces) {
    await sessions.touchWorkspace(
      workspace,
      displayPath: displayPathOf(workspace),
    );
  }
  return sessions;
}

Finder _entry(WorkspaceLocation workspace) =>
    find.byKey(ValueKey('recent_${workspace.id}'));

Finder _inEntry(WorkspaceLocation workspace, String text) =>
    find.descendant(of: _entry(workspace), matching: find.text(text));

Future<void> _openMenu(WidgetTester tester, WorkspaceLocation workspace) async {
  await tester.tap(find.byKey(ValueKey('recent_menu_${workspace.id}')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('New Project creates a project and opens it; a taken name is '
      'explained', (tester) async {
    setSurface(tester, 412, 1400);
    final harness = TestHarness(broker: FakeStorageBroker());
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recents_empty')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new_project')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('project_name_field')),
      'Demo',
    );
    await tester.tap(find.byKey(const ValueKey('project_name_confirm')));
    await tester.pumpAndSettle();
    expect(find.text('A project named "Demo" already exists.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('project_name_field')),
      'my-app',
    );
    await tester.tap(find.byKey(const ValueKey('project_template')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_name_confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    expect(harness.projects.projects['my-app']!.paths, contains('main.js'));
    expect(
      harness.shellStore.load().workspace,
      isA<ProjectLocation>()
          .having((p) => p.name, 'name', 'my-app')
          .having((p) => p.folder, 'folder', 'my-app'),
    );
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('the recents show each workspace with its kind, place and '
      'status', (tester) async {
    setSurface(tester, 412, 1400);
    final broker = FakeStorageBroker()
      ..addTree(_here, 'here')
      ..addTree(_lost, 'lost', grant: false);
    final harness = TestHarness(
      broker: broker,
      sessionStore: await _recorded([
        const DemoProjectLocation(),
        _alpha,
        _gone,
        _hereFolder,
        _lostFolder,
      ]),
      projects: MemoryProjectStorage()..add('alpha'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    for (final workspace in [
      const DemoProjectLocation(),
      _alpha,
      _gone,
      _hereFolder,
      _lostFolder,
    ]) {
      expect(_entry(workspace), findsOneWidget, reason: workspace.name);
    }
    expect(
      _inEntry(_alpha, 'Project · CodeForge projects/alpha'),
      findsOneWidget,
    );
    expect(_inEntry(_alpha, 'available'), findsOneWidget);
    expect(_inEntry(_gone, 'missing'), findsOneWidget);
    expect(
      _inEntry(_hereFolder, 'Folder · Internal storage/here'),
      findsOneWidget,
    );
    expect(_inEntry(_hereFolder, 'available'), findsOneWidget);
    expect(_inEntry(_lostFolder, 'access lost'), findsOneWidget);
    // Most recently opened first.
    expect(
      tester.getTopLeft(_entry(_lostFolder)).dy,
      lessThan(tester.getTopLeft(_entry(_alpha)).dy),
    );
  });

  testWidgets('a project is renamed, then deleted, from its menu', (
    tester,
  ) async {
    setSurface(tester, 412, 1400);
    final projects = MemoryProjectStorage()
      ..add('alpha', files: {'a.js': 'a\n'});
    final harness = TestHarness(
      broker: FakeStorageBroker(),
      sessionStore: await _recorded([_alpha]),
      projects: projects,
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await _openMenu(tester, _alpha);
    await tester.tap(find.byKey(const ValueKey('recent_rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('project_name_field')),
      'beta',
    );
    await tester.tap(find.byKey(const ValueKey('project_name_confirm')));
    await tester.pumpAndSettle();
    expect(projects.projects.keys, ['beta']);
    expect(_inEntry(_alpha, 'beta'), findsOneWidget, reason: 'same id');

    await _openMenu(tester, _alpha);
    await tester.tap(find.byKey(const ValueKey('recent_delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete "beta"?'), findsOneWidget);
    expect(find.textContaining('This deletes 1 file'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home_confirm_ok')));
    await tester.pumpAndSettle();
    expect(projects.projects, isEmpty);
    expect(_entry(_alpha), findsNothing);
  });

  testWidgets('a folder leaves the recents, giving its grant back; its files '
      'stay', (tester) async {
    setSurface(tester, 412, 1400);
    final broker = FakeStorageBroker()
      ..addTree(_here, 'here', files: {'h.txt': 'h\n'});
    final harness = TestHarness(
      broker: broker,
      sessionStore: await _recorded([_hereFolder]),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await _openMenu(tester, _hereFolder);
    await tester.tap(find.byKey(const ValueKey('recent_remove')));
    await tester.pumpAndSettle();
    expect(find.textContaining('stay on the device'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home_confirm_ok')));
    await tester.pumpAndSettle();
    expect(broker.released, [_here]);
    expect(_entry(_hereFolder), findsNothing);
    expect(broker.trees[_here]!.text('h.txt'), 'h\n');
  });

  testWidgets('Reconnect opens the picker at the old place; another folder '
      'replaces the entry once the user agrees', (tester) async {
    setSurface(tester, 412, 1400);
    final broker = FakeStorageBroker()
      ..addTree(_here, 'here').missing = true
      ..addTree(_moved, 'moved', files: {'h.txt': 'h\n'}, grant: false)
      ..pickAnswer = _moved;
    final harness = TestHarness(
      broker: broker,
      sessionStore: await _recorded([_hereFolder]),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    expect(_inEntry(_hereFolder, 'folder missing'), findsOneWidget);

    await _openMenu(tester, _hereFolder);
    await tester.tap(find.byKey(const ValueKey('recent_reconnect')));
    await tester.pumpAndSettle();
    expect(broker.pickStarts.last, folderPickerStart(_here));
    expect(find.text('Replace "here"?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home_confirm_ok')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    final workspace = harness.shellStore.load().workspace! as FolderLocation;
    expect(workspace.id, _hereFolder.id);
    expect(workspace.treeUri, _moved);
    expect(broker.released, [_here]);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('a reconnect turned down gives the picked folder back', (
    tester,
  ) async {
    setSurface(tester, 412, 1400);
    final broker = FakeStorageBroker()
      ..addTree(_here, 'here').missing = true
      ..addTree(_moved, 'moved', grant: false)
      ..pickAnswer = _moved;
    final sessions = await _recorded([_hereFolder]);
    final harness = TestHarness(broker: broker, sessionStore: sessions);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await _openMenu(tester, _hereFolder);
    await tester.tap(find.byKey(const ValueKey('recent_reconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home_confirm_cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new_project')), findsOneWidget);
    expect(broker.released, [_moved]);
    expect(sessions.workspaces[_hereFolder.id]?.location, _here);
  });
}
