/// Folders from shared storage on the emulator (Phase 3 W2, gate G1),
/// part B, after app/tool/ci/emulator_gate.sh stopped part A's process
/// (`am force-stop`) and reinstalled the test build over its data.
///
/// The app starts on its own: the shell remembers the folder and the
/// workbench, and the folder opens again, so its grant survived the
/// process death. A read and a write land, checked on disk. Then the host
/// deletes the folder behind the app's back, and the explorer says it is
/// missing; the host puts an empty folder back and the app gives up its
/// grant, and the explorer says access is lost. No step crashes the app.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/storage_broker.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_fixture.dart';
import 'folder_gate.dart';
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('folders B: the grant survives a process death; a missing '
      'folder and a lost grant show their status', (tester) async {
    final gate = await FolderGate.start();
    // Part A's preferences, as it left them: never cleared here.
    final prefs = await SharedPreferences.getInstance();
    final remembered = PrefsShellStateStore(prefs).load();
    expect(remembered.folder?.name, gateFolderName);
    expect(remembered.lastRoute, '/workspace');
    await pumpRealApp(tester, prefs);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    WorkspaceState workspace() => container.read(workspaceControllerProvider);
    // The workbench reopened the folder by itself: the grant held.
    await pumpUntil(
      tester,
      () => workspace().listings['']?.isOk ?? false,
      what: 'the folder to reopen after the restart',
      timeout: const Duration(seconds: 60),
    );
    final folder = container.read(currentWorkspaceProvider) as FolderLocation;
    expect(workspace().workspace?.displayName, gateFolderName);
    final broker = container.read(storageBrokerProvider);
    final files = container.read(fileServiceProvider);
    expect(
      [for (final grant in (await broker.grants()).orThrow) grant.treeUri],
      contains(folder.treeUri),
    );
    await tester.tap(find.byKey(const ValueKey('activity_explorer')));
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('tree_hello.txt')).evaluate().isNotEmpty,
      what: 'the folder in the explorer',
    );

    // What part A wrote is there, and a new write lands.
    expect((await files.readText('notes/saved.md')).orThrow.text, 'short\n');
    expect(await gate.disk('notes/saved.md'), sha256Of('short\n'));
    const after = 'written after the restart\n';
    expect(
      (await files.writeText(
        'after-restart.txt',
        after,
        mode: WriteMode.createNew,
      )).isOk,
      isTrue,
    );
    expect(await gate.disk('after-restart.txt'), sha256Of(after));

    // Deleted behind the app's back: the explorer says the folder is
    // missing, and reading says so too.
    expect(await gate.ask('rmtree'), 'done');
    expect(await gate.disk('hello.txt'), 'absent');
    await container.read(workspaceControllerProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(
      workspace().listings['']?.failureOrNull,
      failsWith(FileProblem.folderMissing),
    );
    expect(find.textContaining('"$gateFolderName" is missing'), findsOneWidget);
    expect(
      (await files.readText('hello.txt')).failureOrNull,
      failsWith(FileProblem.folderMissing),
    );
    expect(
      (await broker.checkFolder(folder.treeUri)).orThrow.status,
      FolderStatus.missing,
    );

    // An empty folder comes back at the same place, and the app gives up
    // its grant: access is lost, whatever is on disk.
    expect(await gate.ask('mkdir'), 'done');
    expect(
      (await broker.checkFolder(folder.treeUri)).orThrow.status,
      FolderStatus.available,
    );
    expect((await broker.releaseGrant(folder.treeUri)).isOk, isTrue);
    expect(
      [for (final grant in (await broker.grants()).orThrow) grant.treeUri],
      isNot(contains(folder.treeUri)),
    );
    await container.read(workspaceControllerProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(
      workspace().listings['']?.failureOrNull,
      failsWith(FileProblem.accessLost),
    );
    expect(
      find.textContaining('no longer has access to "$gateFolderName"'),
      findsOneWidget,
    );
    expect(
      (await broker.checkFolder(folder.treeUri)).orThrow.status,
      FolderStatus.accessLost,
    );
    gate.done();
  });
}
