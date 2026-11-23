/// The editor's language features through the host (Phase 6 W5): over the
/// real document controller, editor host and language client, with the
/// scripted editor page and the scripted host. The page's requests reach
/// the server at the right place and come back converted; no server means
/// "unavailable" (completion falls back to words); a definition opens its
/// file at the place, or a server's own file read-only; a rename changes
/// open documents through the editor, one undo each, writes closed files,
/// and changes nothing when a file changed after it was computed; the
/// servers' diagnostics reach the page, the status strip's counts, again
/// after the page restarts, and go with their server.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/lsp/lsp_controller.dart';
import 'package:codeforge/application/lsp/lsp_features.dart';
import 'package:codeforge/application/lsp/rename.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/application/settings_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/services/lsp/library_files.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/fake_lsp_clock.dart';
import '../support/fake_runtime_service.dart';
import '../support/fake_storage_broker.dart';
import '../support/memory_file_service.dart';
import '../support/scripted_lsp_service.dart';

const String _root = '$scriptedFilesRoot/workspaces/demo';
String _uri(String path) => 'file://$_root/$path';

Map<String, Object?> _range(int sl, int sc, int el, int ec) => {
  'start': {'line': sl, 'character': sc},
  'end': {'line': el, 'character': ec},
};

Future<void> _drain() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

/// The server's own files, in memory.
final class _Library implements LibraryFiles {
  final Map<String, String> files = {};

  @override
  Future<Result<String>> read(String path, List<String> roots) async {
    if (!isUnderRoots(path, roots)) {
      return const Err(
        FileFailure('Not a server file.', problem: FileProblem.invalidPath),
      );
    }
    final text = files[path];
    return text == null
        ? const Err(FileFailure('Gone.', problem: FileProblem.notFound))
        : Ok(text);
  }
}

final class _World {
  _World() {
    lsp
      ..capabilities = const {
        'textDocumentSync': {
          'openClose': true,
          'change': 2,
          'save': {'includeText': false},
        },
        'completionProvider': {
          'resolveProvider': true,
          'triggerCharacters': ['.', '['],
        },
        'hoverProvider': true,
        'definitionProvider': true,
        'renameProvider': {'prepareProvider': true},
      }
      ..respond = (handle, method, params) {
        final answer = answers[method];
        return answer == null
            ? lsp.defaultAnswer(handle, method, params)
            : {'result': answer(params)};
      };
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        shellStateStoreProvider.overrideWithValue(
          InMemoryShellStateStore(const ShellState()),
        ),
        fileServiceProvider.overrideWithValue(files),
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        storageBrokerProvider.overrideWithValue(FakeStorageBroker()),
        runtimeServiceProvider.overrideWithValue(
          FakeRuntimeService(state: RuntimeState.ready),
        ),
        lspServiceProvider.overrideWithValue(lsp),
        lspClockProvider.overrideWithValue(clock),
        libraryFilesProvider.overrideWithValue(library),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final MemoryFileService files = MemoryFileService();
  final FakeLspClock clock = FakeLspClock();
  final _Library library = _Library();
  late final ScriptedLspService lsp = ScriptedLspService(clock: clock);
  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  /// What the server answers each method with, given its params.
  final Map<String, Object? Function(Object? params)> answers = {};

  DocumentController get documents =>
      container.read(documentControllerProvider.notifier);

  LspFeatures get features => container.read(lspFeaturesProvider.notifier);

  ProblemsState get problems => container.read(lspFeaturesProvider);

  FakeEditorSurface get page => pages.single;

  String docIdOf(String path) =>
      container.read(documentControllerProvider).documents[path]!.docId;

  /// What the client sent the newest server, decoded.
  List<Map<String, Object?>> get sent => lsp.sent[lsp.latest]!;

  Map<String, Object?> lastSent(String method) =>
      sent.lastWhere((m) => m['method'] == method);

  /// The workbench's watch of the features, the editor page, and the
  /// runtime's status.
  Future<void> start() async {
    container.listen(lspFeaturesProvider, (_, _) {});
    await container.read(editorHostProvider).start();
    await container.read(runtimeControllerProvider.notifier).refresh();
    await _drain();
  }

  Future<void> open(String path) async {
    await documents.open(path);
    await _drain();
  }

  /// Asks as the page does, and lets everything that follows settle.
  Future<Map<String, Object?>> ask(
    String type,
    Map<String, Object?> payload,
  ) async {
    final answer = page.request(type, payload);
    await _drain();
    return answer;
  }

  /// Server [handle] publishes [items] for [path] at the version it has.
  void publish(String path, List<Map<String, Object?>> items, {int? version}) {
    final client = container
        .read(lspControllerProvider.notifier)
        .clientFor(LspServerId.pyright)!;
    lsp.deliver(lsp.latest, {
      'jsonrpc': '2.0',
      'method': 'textDocument/publishDiagnostics',
      'params': {
        'uri': _uri(path),
        'version': version ?? client.versionOf(path),
        'diagnostics': items,
      },
    });
  }
}

void main() {
  group('the page asks', () {
    test('completion: at the place, converted, with the server trigger '
        'characters', () async {
      final world = _World();
      world.files.putText('use.py', 'import os\nos.pa');
      world.answers['textDocument/completion'] = (_) => {
        'isIncomplete': false,
        'items': [
          {'label': 'pathsep', 'kind': 6, 'sortText': 'b'},
          {'label': 'path', 'kind': 9, 'sortText': 'a', 'data': 1},
          {'label': 'getcwd', 'kind': 3},
        ],
      };
      await world.start();
      await world.open('use.py');
      final answer = await world.ask('lsp.complete', {
        'docId': world.docIdOf('use.py'),
        'version': 0,
        'pos': 15,
        'trigger': 'invoked',
      });
      expect(answer['ok'], isTrue, reason: '$answer');
      final result = _map(answer['result']);
      expect(
        [
          for (final item in result['items']! as List<Object?>)
            _map(item)['label'],
        ],
        ['path', 'pathsep'],
      );
      expect(result['incomplete'], isFalse);
      expect(result['triggerCharacters'], ['.', '[']);
      final params = _map(world.lastSent('textDocument/completion')['params']);
      expect(params['position'], {'line': 1, 'character': 5});
      expect(params['context'], {'triggerKind': 1});

      // Its documentation, for the item the page selected.
      world.answers['completionItem/resolve'] = (item) => {
        ..._map(item),
        'documentation': {'kind': 'markdown', 'value': 'The path module.'},
      };
      final resolved = await world.ask('lsp.resolve', {
        'docId': world.docIdOf('use.py'),
        'resultId': result['resultId'],
        'index': 0,
      });
      expect(_map(resolved['result'])['documentation'], {
        'kind': 'markdown',
        'value': 'The path module.',
      });
      expect(
        _map(world.lastSent('completionItem/resolve')['params'])['label'],
        'path',
      );
    });

    test('a trigger character goes to the server as one', () async {
      final world = _World();
      world.files.putText('use.py', 'import os\nos.');
      world.answers['textDocument/completion'] = (_) => <Object?>[];
      await world.start();
      await world.open('use.py');
      await world.ask('lsp.complete', {
        'docId': world.docIdOf('use.py'),
        'version': 0,
        'pos': 13,
        'trigger': 'character',
        'character': '.',
      });
      expect(
        _map(world.lastSent('textDocument/completion')['params'])['context'],
        {'triggerKind': 2, 'triggerCharacter': '.'},
      );
    });

    test('no server for the file: unavailable, so completion falls back to '
        'words', () async {
      final world = _World();
      world.files.putText('notes.md', '# notes');
      await world.start();
      await world.open('notes.md');
      final answer = await world.ask('lsp.complete', {
        'docId': world.docIdOf('notes.md'),
        'version': 0,
        'pos': 3,
        'trigger': 'invoked',
      });
      expect(answer['ok'], isFalse);
      expect(_map(answer['error'])['code'], 'unavailable');
    });

    test('a server restarting: unavailable', () async {
      final world = _World();
      world.files.putText('use.py', 'x = 1\n');
      await world.start();
      await world.open('use.py');
      world.lsp.crash(world.lsp.latest);
      await _drain();
      final answer = await world.ask('lsp.hover', {
        'docId': world.docIdOf('use.py'),
        'version': 0,
        'pos': 0,
      });
      expect(_map(answer['error'])['code'], 'unavailable');
    });

    test('hover: the text, and its range as offsets', () async {
      final world = _World();
      world.files.putText('use.py', 'print(greet)\n');
      world.answers['textDocument/hover'] = (_) => {
        'contents': {'kind': 'markdown', 'value': '(function) greet'},
        'range': _range(0, 6, 0, 11),
      };
      await world.start();
      await world.open('use.py');
      final answer = await world.ask('lsp.hover', {
        'docId': world.docIdOf('use.py'),
        'version': 0,
        'pos': 8,
      });
      expect(answer['result'], {
        'contents': {'kind': 'markdown', 'value': '(function) greet'},
        'from': 6,
        'to': 11,
      });
    });
  });

  group('definition', () {
    test('opens the other file at the place', () async {
      final world = _World();
      world.files
        ..putText('people.py', 'import os\n\n\ndef greet(name):\n    pass\n')
        ..putText('main.py', 'from people import greet\ngreet("you")\n');
      world.answers['textDocument/definition'] = (_) => {
        'uri': _uri('people.py'),
        'range': _range(3, 4, 3, 9),
      };
      await world.start();
      await world.open('main.py');
      final answer = await world.ask('lsp.definition', {
        'docId': world.docIdOf('main.py'),
        'version': 0,
        'pos': 27,
      });
      expect(answer['result'], {'found': 1});
      expect(
        world.container.read(documentControllerProvider).activePath,
        'people.py',
      );
      expect(world.page.gotoLines.last, (line: 4, column: 5));
    });

    test("in the server's own files: shown read-only", () async {
      final world = _World();
      world.files.putText('main.py', 'print(len("x"))\n');
      const stub =
          '/rt/codeforge/lsp/pyright/node_modules/pyright/dist/'
          'typeshed-fallback/stdlib/builtins.pyi';
      world.library.files[stub] = 'def len(obj, /) -> int: ...\n';
      world.answers['textDocument/definition'] = (_) => [
        {'uri': 'file://$stub', 'range': _range(0, 4, 0, 7)},
      ];
      await world.start();
      await world.open('main.py');
      final answer = await world.ask('lsp.definition', {
        'docId': world.docIdOf('main.py'),
        'version': 0,
        'pos': 7,
      });
      expect(answer['result'], {'found': 1});
      final view = world.container.read(libraryViewProvider)!;
      expect(view.name, 'builtins.pyi');
      expect(view.where, 'Python stubs: stdlib/builtins.pyi');
      expect(view.line, 0);
      expect(view.text, startsWith('def len'));
      // No tab for it.
      expect(world.container.read(documentControllerProvider).documents.keys, [
        'main.py',
      ]);
    });

    test('outside the workspace and the server files: refused', () async {
      final world = _World();
      world.files.putText('main.py', 'x\n');
      world.answers['textDocument/definition'] = (_) => {
        'uri': 'file:///etc/passwd',
        'range': _range(0, 0, 0, 1),
      };
      await world.start();
      await world.open('main.py');
      final answer = await world.ask('lsp.definition', {
        'docId': world.docIdOf('main.py'),
        'version': 0,
        'pos': 0,
      });
      expect(_map(answer['error'])['code'], 'server_error');
      expect(world.container.read(libraryViewProvider), isNull);
    });
  });

  group('rename', () {
    const people = 'def greet(name):\n    return name\n';
    const main = 'from people import greet\nprint(greet("you"))\n';
    const other = 'from people import greet\ngreet("x")\n';

    /// people.py and main.py open (main.py active), other.py closed; the
    /// server renames greet to welcome in all three.
    Future<_World> setUp() async {
      final world = _World();
      world.files
        ..putText('people.py', people)
        ..putText('main.py', main)
        ..putText('other.py', other);
      world.answers['textDocument/prepareRename'] = (_) => {
        'range': _range(1, 6, 1, 11),
        'placeholder': 'greet',
      };
      world.answers['textDocument/rename'] = (params) => {
        'changes': {
          _uri('people.py'): [
            {'range': _range(0, 4, 0, 9), 'newText': _map(params)['newName']},
          ],
          _uri('main.py'): [
            {'range': _range(1, 6, 1, 11), 'newText': 'welcome'},
            {'range': _range(0, 19, 0, 24), 'newText': 'welcome'},
          ],
          _uri('other.py'): [
            {'range': _range(0, 19, 0, 24), 'newText': 'welcome'},
            {'range': _range(1, 0, 1, 5), 'newText': 'welcome'},
          ],
        },
      };
      await world.start();
      await world.open('people.py');
      await world.open('main.py');
      // Like Pyright, the server watches its files: those a rename writes
      // reach it (W4's client sends changes only to a server that asked).
      world.lsp.deliver(world.lsp.latest, {
        'jsonrpc': '2.0',
        'id': 99,
        'method': 'client/registerCapability',
        'params': {
          'registrations': [
            {
              'id': 'w1',
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
      return world;
    }

    Future<RenameRequest> prepare(_World world) async {
      final answer = await world.ask('lsp.prepareRename', {
        'docId': world.docIdOf('main.py'),
        'version': 0,
        'pos': 32,
      });
      expect(answer['result'], {'from': 31, 'to': 36, 'placeholder': 'greet'});
      return world.container.read(pendingRenameProvider.notifier).take()!;
    }

    test('across files: open documents through the editor, one undo each; '
        'closed files written; a summary', () async {
      final world = await setUp();
      final request = await prepare(world);
      expect(request.oldName, 'greet');
      expect(request.server, LspServerId.pyright);
      final result = await world.features.rename(request, 'welcome');
      await _drain();
      final summary = (result as Ok<RenameSummary>).value;
      expect(summary.paths, ['people.py', 'main.py', 'other.py']);
      expect(summary.written, ['other.py']);
      expect(summary.edits, 5);
      expect(
        summary.message,
        'Renamed greet to welcome in 3 files: people.py, main.py, other.py',
      );
      final page = world.page;
      final host = world.container.read(editorHostProvider);
      expect(
        page.documents[world.docIdOf('main.py')]!.text,
        'from people import welcome\nprint(welcome("you"))\n',
      );
      expect(
        host.textOf(world.docIdOf('people.py')),
        'def welcome(name):\n    return name\n',
      );
      expect(
        (await world.files.readText('other.py')).valueOrNull?.text,
        'from people import welcome\nwelcome("x")\n',
      );
      // The open documents changed in the editor, not on disk.
      expect((await world.files.readText('main.py')).valueOrNull?.text, main);
      expect(
        _map(_map(world.lastSent('textDocument/rename')['params'])['position']),
        {'line': 1, 'character': 7},
      );
      // The server hears of the file written.
      final watched = world.lastSent('workspace/didChangeWatchedFiles');
      expect(_map(watched['params'])['changes'], [
        {'uri': _uri('other.py'), 'type': 2},
      ]);
      // One undo takes the rename back in each open document.
      page.undoRename(world.docIdOf('main.py'));
      await _drain();
      expect(host.textOf(world.docIdOf('main.py')), main);
      expect(page.undoStack[world.docIdOf('people.py')], hasLength(1));
    });

    test(
      'nothing changes when a closed file changed after it was computed',
      () async {
        final world = await setUp();
        final request = await prepare(world);
        final rename = world.answers['textDocument/rename']!;
        world.answers['textDocument/rename'] = (params) {
          // Another program edits other.py while the server works.
          world.files.putText('other.py', '# moved\n$other');
          return rename(params);
        };
        final result = await world.features.rename(request, 'welcome');
        await _drain();
        expect(result, isA<Err<RenameSummary>>());
        expect(
          (result as Err<RenameSummary>).failure.message,
          'Nothing was renamed: other.py changed after the rename was computed.',
        );
        expect(world.page.documents[world.docIdOf('main.py')]!.text, main);
        expect(world.page.undoStack, isEmpty);
        expect(
          (await world.files.readText('other.py')).valueOrNull?.text,
          '# moved\n$other',
        );
      },
    );

    test('nothing changes when an open document moved on while it was '
        'computed', () async {
      final world = await setUp();
      final request = await prepare(world);
      final rename = world.answers['textDocument/rename']!;
      world.answers['textDocument/rename'] = (params) {
        world.page.typeText('# typed\n', docId: world.docIdOf('people.py'));
        return rename(params);
      };
      final result = await world.features.rename(request, 'welcome');
      await _drain();
      expect(
        (result as Err<RenameSummary>).failure.message,
        'Nothing was renamed: people.py changed after the rename was computed.',
      );
      expect(world.files.writes, isNot(contains('other.py')));
    });

    test('a closed file stamped after the request is refused', () async {
      final world = await setUp();
      final request = await prepare(world);
      final client = world.container
          .read(lspControllerProvider.notifier)
          .clientFor(LspServerId.pyright)!;
      // The in-memory files are stamped in seconds from the epoch.
      final result = await runRename(
        request: request,
        newName: 'welcome',
        client: client,
        host: world.container.read(editorHostProvider),
        files: world.files,
        documents: () => world.container.read(documentControllerProvider),
        written: (_) {},
        now: () => DateTime.fromMillisecondsSinceEpoch(500),
      );
      expect(
        (result as Err<RenameSummary>).failure.message,
        contains('changed after the rename was computed'),
      );
      expect(world.page.undoStack, isEmpty);
    });

    test('a server that renames files is refused', () async {
      final world = await setUp();
      final request = await prepare(world);
      world.answers['textDocument/rename'] = (_) => {
        'documentChanges': [
          {
            'kind': 'rename',
            'oldUri': _uri('people.py'),
            'newUri': _uri('x.py'),
          },
        ],
      };
      final result = await world.features.rename(request, 'welcome');
      expect(
        (result as Err<RenameSummary>).failure.message,
        contains('rename or delete files'),
      );
    });

    test('nothing to rename: the page hears why', () async {
      final world = await setUp();
      world.answers['textDocument/prepareRename'] = (_) => null;
      final answer = await world.ask('lsp.prepareRename', {
        'docId': world.docIdOf('main.py'),
        'version': 0,
        'pos': 32,
      });
      expect(_map(answer['error'])['code'], 'server_error');
      expect(world.container.read(pendingRenameProvider), isNull);
    });
  });

  group('diagnostics', () {
    Map<String, Object?> problem(int line, int from, int to, int severity) => {
      'range': _range(line, from, line, to),
      'severity': severity,
      'message': 'problem $line:$from',
      'source': 'Pyright',
    };

    test('reach the page as offsets and the counts, and an empty list clears '
        'them', () async {
      final world = _World();
      world.files.putText('main.py', 'import os\nprint(greet)\n');
      await world.start();
      await world.open('main.py');
      world.publish('main.py', [problem(1, 6, 11, 1), problem(0, 7, 9, 2)]);
      await _drain();
      final docId = world.docIdOf('main.py');
      final shown = world.page.diagnostics[docId]!;
      expect(shown.version, 0);
      expect(shown.items.first, {
        'from': 16,
        'to': 21,
        'severity': 'error',
        'message': 'problem 1:6',
        'source': 'Pyright',
      });
      expect(
        world.problems.countsOf('main.py'),
        const ProblemCounts(errors: 1, warnings: 1),
      );
      world.publish('main.py', []);
      await _drain();
      expect(world.page.diagnostics[docId]!.items, isEmpty);
      expect(world.problems.files, isEmpty);
    });

    test('a set found in an older version is ignored', () async {
      final world = _World();
      world.files.putText('main.py', 'x = 1\n');
      await world.start();
      await world.open('main.py');
      world.page.typeText('y = 2\n');
      await _drain();
      world.publish('main.py', [problem(0, 0, 1, 1)], version: 0);
      await _drain();
      expect(world.page.diagnostics, isEmpty);
      expect(world.problems.files, isEmpty);
    });

    test('are sent again after the page restarts', () async {
      final world = _World();
      world.files.putText('main.py', 'x = 1\n');
      await world.start();
      await world.open('main.py');
      world.publish('main.py', [problem(0, 0, 1, 1)]);
      await _drain();
      world.page.restartPage();
      await _drain();
      expect(
        world.page.diagnostics[world.docIdOf('main.py')]!.items,
        hasLength(1),
      );
    });

    test('go with the server that found them', () async {
      final world = _World();
      world.files.putText('main.py', 'x = 1\n');
      await world.start();
      await world.open('main.py');
      world.publish('main.py', [problem(0, 0, 1, 1)]);
      await _drain();
      expect(world.problems.files, isNotEmpty);
      await world.container
          .read(settingsControllerProvider.notifier)
          .setLanguageServer(LspServerId.pyright, false);
      await _drain();
      expect(world.problems.files, isEmpty);
      expect(world.page.diagnostics[world.docIdOf('main.py')]!.items, isEmpty);
    });
  });
}
