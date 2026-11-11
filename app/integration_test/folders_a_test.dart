/// Folders from shared storage on the emulator (Phase 3 W2, gate G1),
/// part A: Android's real folder picker, then every operation through the
/// real provider, each checked on disk by the host.
///
/// app/tool/ci/emulator_gate.sh puts /sdcard/Documents/cf-gate (and a
/// folder beside it) on the device with `adb push`
/// (integration_test/folder_fixture.dart). The test taps Open Folder, and
/// the host drives the picker with `uiautomator dump` and `input tap`
/// ("Use this folder", then "Allow"), the way the keys group's injector
/// answers requests (integration_test/folder_gate.dart). The test then
/// lists, reads, writes (a shorter text over a longer one too), saves
/// through the editor, creates, renames (case only too), moves, copies and
/// deletes; the host checks each result with `sha256sum` or `ls`. Paths
/// that leave the folder, and folders the app was never granted, are
/// refused. The app ends with the folder open; the host stops its process,
/// and part B (folders_b_test.dart) starts it again.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_fixture.dart';
import 'folder_gate.dart';
import 'smoke_test.dart' show pumpUntil;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('folders A: the picker, then every operation checked on disk', (
    tester,
  ) async {
    final gate = await FolderGate.start();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(PrefsSettingsStore(prefs)),
          shellStateStoreProvider.overrideWithValue(
            PrefsShellStateStore(prefs),
          ),
          // The picker opens inside the gate folder (W3's Reconnect opens
          // it at a folder's old place the same way).
          folderPickerStartProvider.overrideWithValue(gateFolderStartUri),
        ],
        child: const CodeForgeApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();

    // The real button, and Android's real picker, driven by the host.
    await tester.tap(find.byKey(const ValueKey('open_folder')));
    await tester.pump();
    expect(
      await gate.ask(
        'pick $gateFolderName',
        timeout: const Duration(seconds: 240),
      ),
      'picked',
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    await pumpUntil(
      tester,
      () => container.read(currentWorkspaceProvider) is FolderLocation,
      what: 'the picked folder to open',
      timeout: const Duration(seconds: 60),
    );
    final folder = container.read(currentWorkspaceProvider) as FolderLocation;
    expect(folder.name, gateFolderName);
    final uri = folder.treeUri;
    final broker = container.read(storageBrokerProvider);
    final files = container.read(fileServiceProvider);

    // The workbench shows the folder: the explorer lists what the host
    // pushed.
    await pumpUntil(
      tester,
      () =>
          find.byKey(const ValueKey('activity_explorer')).evaluate().isNotEmpty,
      what: 'the workbench',
    );
    await tester.tap(find.byKey(const ValueKey('activity_explorer')));
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('tree_hello.txt')).evaluate().isNotEmpty,
      what: 'the folder in the explorer',
    );
    expect(find.byKey(const ValueKey('tree_src')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree_Readme.md')), findsOneWidget);
    // Close the explorer sheet (phones): tap above it.
    if (find.byType(DraggableScrollableSheet).evaluate().isNotEmpty) {
      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();
    }

    // The grant is kept, for reading and writing.
    final grant = (await broker.grants()).orThrow.where(
      (g) => g.treeUri == uri,
    );
    expect(grant, hasLength(1));
    expect(grant.single.write, isTrue);

    // List and read through the file service: exactly the pushed files.
    final root = (await files.listDirectory('')).orThrow;
    expect(
      [for (final entry in root) entry.name],
      ['notes', 'src', 'hello.txt', 'Readme.md'],
    );
    for (final MapEntry(key: path, value: text) in gateFixture.entries) {
      expect((await files.readText(path)).orThrow.text, text, reason: path);
    }
    expect(await gate.disk('hello.txt'), sha256Of(gateFixture['hello.txt']!));

    // Write: a new file, then a shorter text over a longer one. Mode "wt"
    // truncates; plain "w" could leave the old tail behind.
    const long = 'A much longer first version of the note, to be cut short.\n';
    const short = 'short\n';
    var stamp = (await files.writeText(
      'notes/saved.md',
      long,
      mode: WriteMode.createNew,
    )).orThrow;
    expect(await gate.disk('notes/saved.md'), sha256Of(long));
    stamp = (await files.writeText(
      'notes/saved.md',
      short,
      expected: stamp,
    )).orThrow;
    expect(stamp.size, short.length);
    expect(await gate.disk('notes/saved.md'), sha256Of(short));
    // A stamp that no longer matches is refused, and the file kept.
    expect(
      (await files.writeText(
        'notes/saved.md',
        'stale\n',
        expected: (await files.readText('hello.txt')).orThrow.stamp,
      )).failureOrNull,
      failsWith(FileProblem.changedOnDisk),
    );
    expect(await gate.disk('notes/saved.md'), sha256Of(short));

    // Save through the editor: the document turns clean only once the
    // write is confirmed.
    final host = container.read(editorHostProvider);
    await pumpUntil(
      tester,
      () =>
          host.status.phase == EditorHostPhase.ready ||
          host.status.phase == EditorHostPhase.failed,
      what: 'the editor page to start',
    );
    expect(
      host.status.phase,
      EditorHostPhase.ready,
      reason: host.status.message,
    );
    final documents = container.read(documentControllerProvider.notifier);
    expect((await documents.open('src/app.js')).isOk, isTrue);
    await tester.pumpAndSettle();
    final docId = container
        .read(documentControllerProvider)
        .documents['src/app.js']!
        .docId;
    const edited = "console.log('saved from CodeForge');\n";
    expect((await host.replaceText(docId, edited)).isOk, isTrue);
    await pumpUntil(
      tester,
      () => container
          .read(documentControllerProvider)
          .documents['src/app.js']!
          .dirty,
      what: 'the edit to reach the document',
    );
    expect((await documents.save('src/app.js')).isOk, isTrue);
    expect(
      container.read(documentControllerProvider).documents['src/app.js']!.dirty,
      isFalse,
    );
    expect(await gate.disk('src/app.js'), sha256Of(edited));

    // Create a file and a folder; a taken name, case ignored, makes nothing.
    expect(
      (await broker.create(uri, 'notes', 'empty.txt', directory: false)).isOk,
      isTrue,
    );
    expect(await gate.disk('notes/empty.txt'), sha256Of(''));
    expect(
      (await broker.create(uri, '', 'made', directory: true)).isOk,
      isTrue,
    );
    expect(await gate.disk('made'), 'dir');
    expect(
      (await broker.create(
        uri,
        '',
        'HELLO.TXT',
        directory: false,
      )).failureOrNull,
      failsWith(FileProblem.exists),
    );
    expect(await gate.names(''), 'Readme.md,hello.txt,made,notes,src');

    // Rename, and a rename that changes only the case: through a temporary
    // name, never " (1)", and nothing left behind.
    expect(
      (await broker.rename(uri, 'notes/empty.txt', 'renamed.txt')).orThrow.name,
      'renamed.txt',
    );
    expect(await gate.disk('notes/empty.txt'), 'absent');
    expect(await gate.disk('notes/renamed.txt'), sha256Of(''));
    expect(
      (await broker.rename(uri, 'Readme.md', 'README.md')).orThrow.name,
      'README.md',
    );
    expect(await gate.names(''), 'README.md,hello.txt,made,notes,src');
    expect(await gate.disk('README.md'), sha256Of(gateFixture['Readme.md']!));

    // Move a file, then a folder with what is in it.
    expect((await broker.move(uri, 'notes/renamed.txt', 'made')).isOk, isTrue);
    expect(await gate.disk('notes/renamed.txt'), 'absent');
    expect(await gate.disk('made/renamed.txt'), sha256Of(''));
    expect((await broker.move(uri, 'src/lib', 'made')).isOk, isTrue);
    expect(await gate.disk('src/lib'), 'absent');
    expect(
      await gate.disk('made/lib/util.js'),
      sha256Of(gateFixture['src/lib/util.js']!),
    );

    // Copy a file, then a folder with what is in it; the originals stay.
    expect(
      (await broker.copy(uri, 'hello.txt', 'made', 'hello-copy.txt')).isOk,
      isTrue,
    );
    expect(
      await gate.disk('made/hello-copy.txt'),
      sha256Of(gateFixture['hello.txt']!),
    );
    expect((await broker.copy(uri, 'made', '', 'made-copy')).isOk, isTrue);
    expect(
      await gate.disk('made-copy/lib/util.js'),
      sha256Of(gateFixture['src/lib/util.js']!),
    );
    expect(await gate.disk('made-copy/renamed.txt'), sha256Of(''));
    expect(await gate.disk('hello.txt'), sha256Of(gateFixture['hello.txt']!));

    // Delete a file, then a folder with what is in it.
    expect((await broker.delete(uri, 'made/hello-copy.txt')).isOk, isTrue);
    expect(await gate.disk('made/hello-copy.txt'), 'absent');
    expect((await broker.delete(uri, 'made-copy')).isOk, isTrue);
    expect(await gate.disk('made-copy'), 'absent');
    expect(await gate.names(''), 'README.md,hello.txt,made,notes,src');

    // Nothing outside the folder is reachable. Paths that leave it are
    // refused by the broker itself, not only by Dart's own check.
    for (final path in [
      '..',
      '../$gateOutsideName/secret.txt',
      'src/../../$gateOutsideName/secret.txt',
      '/sdcard/Documents/$gateOutsideName/secret.txt',
    ]) {
      expect(
        (await broker.read(uri, path, maxBytes: 1024)).failureOrNull,
        failsWith(FileProblem.invalidPath),
        reason: path,
      );
    }
    // Folders the app was never granted: the one beside it, and the
    // shared Documents folder above both.
    for (final other in [gateOutsideTreeUri, gateDocumentsTreeUri]) {
      expect(
        (await broker.list(other, '')).failureOrNull,
        failsWith(FileProblem.accessLost),
        reason: other,
      );
    }
    expect(
      (await broker.read(
        gateOutsideTreeUri,
        'secret.txt',
        maxBytes: 1024,
      )).failureOrNull,
      failsWith(FileProblem.accessLost),
    );
    // A document URI is not a grant.
    expect(
      (await broker.list(gateFolderStartUri, '')).failureOrNull,
      failsWith(FileProblem.invalidPath),
    );

    // Part B runs after a process death: the shell must remember the
    // folder and the workbench (written at once, and after 400 ms).
    await container.read(shellControllerProvider.notifier).flush();
    gate.done();
  });
}
