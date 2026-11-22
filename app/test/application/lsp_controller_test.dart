/// The language servers in the app (Phase 6 W4): over the real document
/// controller, the scripted editor page and the scripted host, a document of
/// a server's languages is shown to it once activated, its typing follows as
/// ranges, its save and its close too; the watcher's listings become
/// `didChangeWatchedFiles`; nothing starts without the runtime or in a
/// folder; and the status, Restart included, is the controller's.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/lsp/lsp_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/core/lsp/text_sync.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/fake_lsp_clock.dart';
import '../support/fake_runtime_service.dart';
import '../support/memory_file_service.dart';
import '../support/scripted_lsp_service.dart';

const String _rootUri = 'file://$scriptedFilesRoot/workspaces/demo';

Future<void> _drain() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

final class _World {
  _World({bool runtimeReady = true, ShellState? shell}) {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        shellStateStoreProvider.overrideWithValue(
          InMemoryShellStateStore(shell),
        ),
        fileServiceProvider.overrideWithValue(files),
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        runtimeServiceProvider.overrideWithValue(
          FakeRuntimeService(
            state: runtimeReady ? RuntimeState.ready : RuntimeState.installed,
          ),
        ),
        lspServiceProvider.overrideWithValue(lsp),
        lspClockProvider.overrideWithValue(clock),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final MemoryFileService files = MemoryFileService();
  final FakeLspClock clock = FakeLspClock();
  late final ScriptedLspService lsp = ScriptedLspService(clock: clock);
  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  DocumentController get documents =>
      container.read(documentControllerProvider.notifier);

  LspController get controller =>
      container.read(lspControllerProvider.notifier);

  LspState get state => container.read(lspControllerProvider);

  FakeEditorSurface get page => pages.single;

  /// The status strip's watch, the editor page, and the runtime's status.
  Future<void> start() async {
    container.listen(lspControllerProvider, (previous, next) {});
    await container.read(editorHostProvider).start();
    await container.read(runtimeControllerProvider.notifier).refresh();
    await _drain();
  }
}

void main() {
  test('a Python file shown starts Pyright in the project, and its typing '
      'follows as ranges', () async {
    final world = _World();
    await world.start();
    expect(world.state.available, isTrue);
    expect(world.state.offReason, isNull);
    await world.documents.open('app.py');
    await _drain();
    final handle = world.lsp.latest;
    expect(world.lsp.starts.single.server, LspServerId.pyright);
    expect(
      world.lsp.starts.single.workspace,
      const LspWorkspace.project('demo'),
    );
    expect(world.lsp.methods(handle), [
      'initialize',
      'initialized',
      'textDocument/didOpen',
    ]);
    final opened = _map(
      world.lsp.paramsOf(handle, 'textDocument/didOpen').single['textDocument'],
    );
    final text = DemoWorkspace.files['app.py']!;
    expect(opened['uri'], '$_rootUri/app.py');
    expect(opened['languageId'], 'python');
    expect(opened['text'], text);
    expect(
      world.state.statusOf(LspServerId.pyright),
      const LspStatus(LspPhase.ready),
    );

    world.page.typeText('\nprint(1)');
    await _drain();
    final change = world.lsp.paramsOf(handle, 'textDocument/didChange').single;
    final end = LineIndex(text).positionAt(text.length).toJson();
    expect(change['contentChanges'], [
      {
        'range': {'start': end, 'end': end},
        'text': '\nprint(1)',
      },
    ]);
    expect(
      _map(change['textDocument'])['version'] as int,
      greaterThan(opened['version']! as int),
    );
  });

  test('a JavaScript file goes to the TypeScript server', () async {
    final world = _World();
    await world.start();
    await world.documents.open('main.js');
    await _drain();
    expect(world.lsp.starts.single.server, LspServerId.typescript);
    expect(
      _map(
        world.lsp
            .paramsOf(world.lsp.latest, 'textDocument/didOpen')
            .single['textDocument'],
      )['languageId'],
      'javascript',
    );
    expect(world.state.statusOf(LspServerId.typescript).phase, LspPhase.ready);
    expect(world.state.statusOf(LspServerId.pyright), LspStatus.off);
  });

  test('saving sends didSave, and closing the tab didClose', () async {
    final world = _World();
    await world.start();
    await world.documents.open('app.py');
    await _drain();
    world.page.typeText('# more\n');
    await _drain();
    expect((await world.documents.save('app.py')).isOk, isTrue);
    await _drain();
    final handle = world.lsp.latest;
    expect(world.lsp.methods(handle), contains('textDocument/didSave'));
    world.documents.close('app.py');
    await _drain();
    expect(world.lsp.methods(handle).last, 'textDocument/didClose');
  });

  test(
    "the watcher's listings become the files a server asked about",
    () async {
      final world = _World();
      await world.start();
      await world.documents.open('app.py');
      await _drain();
      final handle = world.lsp.latest;
      world.lsp.deliver(handle, {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'client/registerCapability',
        'params': {
          'registrations': [
            {
              'id': 'w',
              'method': 'workspace/didChangeWatchedFiles',
              'registerOptions': {
                'watchers': [
                  {'globPattern': '**/*.py'},
                ],
              },
            },
          ],
        },
      });
      await _drain();
      FileEntry file(String name, int size) => FileEntry(
        path: name,
        name: name,
        isDirectory: false,
        sizeBytes: size,
      );
      world.controller
        // The first listing is only remembered.
        ..folderListed('', [file('app.py', 10), file('old.py', 3)])
        ..folderListed('', [file('app.py', 12), file('new.py', 1)]);
      await _drain();
      expect(
        world.lsp
            .paramsOf(handle, 'workspace/didChangeWatchedFiles')
            .single['changes'],
        [
          {'uri': '$_rootUri/app.py', 'type': 2},
          {'uri': '$_rootUri/new.py', 'type': 1},
          {'uri': '$_rootUri/old.py', 'type': 3},
        ],
      );
    },
  );

  test('a server that gave up is offered for Restart, which starts it '
      'again', () async {
    final world = _World();
    await world.start();
    await world.documents.open('app.py');
    await _drain();
    for (var crash = 0; crash < 4; crash++) {
      world.lsp.crash(world.lsp.latest);
      await _drain();
      world.clock.advance(const Duration(seconds: 4));
      await _drain();
    }
    final gaveUp = world.state.statusOf(LspServerId.pyright);
    expect(gaveUp.phase, LspPhase.off);
    expect(gaveUp.canRestart, isTrue);
    await world.controller.restart(LspServerId.pyright);
    await _drain();
    expect(world.state.statusOf(LspServerId.pyright).phase, LspPhase.ready);
    expect(world.lsp.starts, hasLength(5));
  });

  test('without the runtime nothing starts, and the chip says why', () async {
    final world = _World(runtimeReady: false);
    await world.start();
    await world.documents.open('app.py');
    await _drain();
    expect(world.lsp.starts, isEmpty);
    expect(world.state.available, isTrue);
    expect(world.state.offReason, 'The Linux runtime is not ready');
    expect(
      world.state.statusOf(LspServerId.pyright),
      const LspStatus(LspPhase.off, reason: 'The Linux runtime is not ready'),
    );
  });

  test('a folder from shared storage gets no server yet', () async {
    final world = _World(
      shell: const ShellState(
        workspace: FolderLocation(treeUri: 'content://tree/x', name: 'X'),
      ),
    );
    await world.start();
    await world.documents.open('app.py');
    await _drain();
    expect(world.lsp.starts, isEmpty);
    expect(world.state.offReason, 'Not yet for folders from shared storage');
  });
}
