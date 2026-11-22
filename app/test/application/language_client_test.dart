/// One language server's client against the fake transport (Phase 6 W4,
/// gate G4): the handshake; documents opened, changed in order with their
/// versions, saved and closed; requests that wait for the page's version,
/// time out, or fail while the server restarts; the server's own requests;
/// file watchers; diagnostics routed by URI, in projects and in copies;
/// progress; the restart backoff and its cap; the idle stop; and the
/// stages of each request's time.
library;

import 'package:codeforge/application/lsp/language_client.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_lsp_clock.dart';
import '../support/scripted_lsp_service.dart';

const String _root = '$scriptedFilesRoot/workspaces/demo';
const String _rootUri = 'file://$_root';

Future<void> _drain() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Matcher _fails(LspProblem problem) => isA<Err<Object?>>().having(
  (e) => e.failure,
  'failure',
  isA<LspFailure>().having((f) => f.problem, 'problem', problem),
);

Map<String, Object?> _range(int l1, int c1, int l2, int c2) => {
  'start': {'line': l1, 'character': c1},
  'end': {'line': l2, 'character': c2},
};

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

/// A client over the scripted host, on the fake clock.
final class _World {
  _World({
    this.server = LspServerId.pyright,
    this.workspace = const LspWorkspace.project('demo'),
  }) {
    service = ScriptedLspService(clock: clock);
    client = LanguageClient(
      server: server,
      workspace: workspace,
      service: service,
      clock: clock,
    );
    client.statusChanges.listen(statuses.add);
    client.diagnosticsChanges.listen(diagnostics.add);
  }

  /// A Pyright client with a.py open and the server ready.
  static Future<_World> ready({String text = 'a = 1\n', int version = 1}) async {
    final world = _World()..open('a.py', text: text, version: version);
    await _drain();
    expect(world.client.status.phase, LspPhase.ready);
    return world;
  }

  final LspServerId server;
  final LspWorkspace workspace;
  final FakeLspClock clock = FakeLspClock();
  late final ScriptedLspService service;
  late final LanguageClient client;
  final List<LspStatus> statuses = [];
  final List<LspDiagnostics> diagnostics = [];

  int get handle => service.latest;

  void open(
    String path, {
    String text = '',
    int version = 1,
    String language = 'python',
  }) => client.open(path, language: language, version: version, text: text);

  List<String> get methods => service.methods(handle);

  void deliver(Map<String, Object?> message) =>
      service.deliver(handle, {'jsonrpc': '2.0', ...message});

  /// Answers the newest request the client sent.
  void answerLast(Object? result) {
    final request = service.sent[handle]!.lastWhere(
      (message) => message.containsKey('id') && message.containsKey('method'),
    );
    deliver({'id': request['id'], 'result': result});
  }
}

void main() {
  group('the session', () {
    test('initialize offers UTF-16 and one workspace folder; then the '
        'documents go', () async {
      final world = _World()..open('src/main.py', text: 'x = 1\n', version: 3);
      await _drain();
      expect(world.service.starts.single.server, LspServerId.pyright);
      expect(
        world.service.starts.single.workspace,
        const LspWorkspace.project('demo'),
      );
      expect(world.methods, [
        'initialize',
        'initialized',
        'textDocument/didOpen',
      ]);
      final init = world.service.paramsOf(world.handle, 'initialize').single;
      expect(init['rootUri'], _rootUri);
      expect(init['rootPath'], _root);
      expect(init['workspaceFolders'], [
        {'uri': _rootUri, 'name': 'demo'},
      ]);
      expect(_map(init['capabilities'])['general'], {
        'positionEncodings': ['utf-16'],
      });
      expect(_map(init['clientInfo'])['name'], 'CodeForge');
      expect(init['initializationOptions'], isEmpty);
      final opened = world.service
          .paramsOf(world.handle, 'textDocument/didOpen')
          .single;
      expect(opened['textDocument'], {
        'uri': '$_rootUri/src/main.py',
        'languageId': 'python',
        'version': 3,
        'text': 'x = 1\n',
      });
      expect(world.client.status, const LspStatus(LspPhase.ready));
      expect(world.statuses.map((s) => s.phase), [
        LspPhase.starting,
        LspPhase.ready,
      ]);
      expect(world.client.uriOf('src/main.py'), '$_rootUri/src/main.py');
      expect(world.client.pathOf('$_rootUri/src/main.py'), 'src/main.py');
    });

    test("TypeScript runs the APK's tsserver, one process, no typings "
        'fetched', () async {
      final world = _World(server: LspServerId.typescript)
        ..open('a.ts', text: 'let a = 1;\n', language: 'typescript')
        ..open('b.tsx', language: 'tsx')
        ..open('c.jsx', language: 'jsx');
      await _drain();
      final init = world.service.paramsOf(world.handle, 'initialize').single;
      expect(init['initializationOptions'], {
        'tsserver': {
          'path':
              '/rt/codeforge/lsp/typescript/node_modules/typescript/lib/'
              'tsserver.js',
          'useSyntaxServer': 'never',
        },
        'disableAutomaticTypingAcquisition': true,
      });
      expect(
        world.service
            .paramsOf(world.handle, 'textDocument/didOpen')
            .map((p) => _map(p['textDocument'])['languageId']),
        ['typescript', 'typescriptreact', 'javascriptreact'],
      );
    });

    test("a folder's copy is the workspace folder, and its documents are "
        'named under it', () async {
      final world = _World(workspace: const LspWorkspace.copy('f3a9'))
        ..open('pkg/a b.py');
      await _drain();
      const copyUri = 'file://$scriptedFilesRoot/copies/f3a9';
      final init = world.service.paramsOf(world.handle, 'initialize').single;
      expect(init['workspaceFolders'], [
        {'uri': copyUri, 'name': 'f3a9'},
      ]);
      expect(
        _map(
          world.service
              .paramsOf(world.handle, 'textDocument/didOpen')
              .single['textDocument'],
        )['uri'],
        '$copyUri/pkg/a%20b.py',
      );
      world.deliver({
        'method': 'textDocument/publishDiagnostics',
        'params': {
          'uri': '$copyUri/pkg/a%20b.py',
          'diagnostics': [
            {
              'range': _range(0, 0, 0, 1),
              'message': 'bad',
              'severity': 2,
            },
          ],
        },
      });
      await _drain();
      expect(world.client.diagnostics.keys, ['pkg/a b.py']);
      expect(
        world.client.diagnostics['pkg/a b.py']!.items.single.severity,
        LspSeverity.warning,
      );
    });

    test("the server's settings come from a fixed table, and its other "
        'requests are answered', () async {
      final world = await _World.ready();
      world
        ..deliver({
          'id': 1,
          'method': 'workspace/configuration',
          'params': {
            'items': [
              {'section': 'python'},
              {'section': 'python.analysis'},
              {'section': 'editor.fontSize'},
              <String, Object?>{},
            ],
          },
        })
        ..deliver({
          'id': 2,
          'method': 'window/workDoneProgress/create',
          'params': {'token': 't'},
        })
        ..deliver({'id': 3, 'method': 'workspace/workspaceFolders'})
        ..deliver({'id': 4, 'method': 'custom/thing'})
        ..deliver({
          'id': 5,
          'method': 'workspace/applyEdit',
          'params': {'edit': <String, Object?>{}},
        });
      await _drain();
      final answers = {
        for (final answer in world.service.answers(world.handle))
          answer['id']: answer,
      };
      expect(answers[1]!['result'], [
        {'pythonPath': '/rt/usr/bin/python'},
        {
          'diagnosticMode': 'openFilesOnly',
          'autoSearchPaths': true,
          'useLibraryCodeForTypes': true,
        },
        null,
        null,
      ]);
      expect(answers[2]!.containsKey('result'), isTrue);
      expect(answers[2]!['result'], isNull);
      expect(answers[3]!['result'], [
        {'uri': _rootUri, 'name': 'demo'},
      ]);
      expect(_map(answers[4]!['error'])['code'], -32601);
      expect(_map(answers[5]!['result'])['applied'], isFalse);
    });

    test('its log lines reach the app log, at most 20 a minute', () async {
      final records = <LogRecord>[];
      void sink(LogRecord record) {
        if (record.tag == 'lsp') {
          records.add(record);
        }
      }

      appLogger.addSink(sink);
      addTearDown(() => appLogger.removeSink(sink));
      final world = await _World.ready();
      for (var i = 0; i < 25; i++) {
        world.deliver({
          'method': 'window/logMessage',
          'params': {'type': 4, 'message': 'line $i'},
        });
      }
      await _drain();
      expect(records.where((r) => r.event == 'server_log'), hasLength(20));
      world.clock.advance(const Duration(minutes: 1));
      world.deliver({
        'method': 'window/logMessage',
        'params': {'type': 1, 'message': 'x' * 1000},
      });
      await _drain();
      final dropped = records.singleWhere(
        (r) => r.event == 'server_log_dropped',
      );
      expect(dropped.fields['lines'], 5);
      final error = records.singleWhere((r) => r.event == 'server_error');
      expect((error.fields['message']! as String).length, 301);
    });
  });

  group('documents', () {
    test('edits go as ranges, last first, with their versions in order', () async {
      final world = await _World.ready(text: 'alpha\nbeta\n');
      expect(
        world.client.applyEdit(
          'a.py',
          baseVersion: 1,
          version: 2,
          changes: [
            [1, 'A'],
            5,
            [4, 'B'],
            1,
          ],
        ),
        isTrue,
      );
      expect(
        world.client.applyEdit(
          'a.py',
          baseVersion: 2,
          version: 3,
          changes: [
            6,
            [0, '>'],
            2,
          ],
        ),
        isTrue,
      );
      await _drain();
      final changes = world.service.paramsOf(
        world.handle,
        'textDocument/didChange',
      );
      expect(changes.map((c) => _map(c['textDocument'])), [
        {'uri': '$_rootUri/a.py', 'version': 2},
        {'uri': '$_rootUri/a.py', 'version': 3},
      ]);
      expect(changes.first['contentChanges'], [
        {'range': _range(1, 0, 1, 4), 'text': 'B'},
        {'range': _range(0, 0, 0, 1), 'text': 'A'},
      ]);
      expect(changes.last['contentChanges'], [
        {'range': _range(1, 0, 1, 0), 'text': '>'},
      ]);
      expect(world.client.versionOf('a.py'), 3);
    });

    test('an edit that does not follow is refused, the whole text goes '
        'instead, and versions only grow', () async {
      final world = await _World.ready(text: 'one\n');
      // The client missed version 2.
      expect(
        world.client.applyEdit(
          'a.py',
          baseVersion: 2,
          version: 3,
          changes: [4, [0, 'x']],
        ),
        isFalse,
      );
      world.client.replaceText('a.py', version: 3, text: 'one\ntwo\n');
      // An edit the whole text already holds is done.
      expect(
        world.client.applyEdit(
          'a.py',
          baseVersion: 2,
          version: 3,
          changes: [4, [0, 'x']],
        ),
        isTrue,
      );
      // A change set that does not fit is refused too.
      expect(
        world.client.applyEdit(
          'a.py',
          baseVersion: 3,
          version: 4,
          changes: [99],
        ),
        isFalse,
      );
      // A resync at the version it holds, with other text, still moves the
      // server's version on.
      world.client.replaceText('a.py', version: 3, text: 'three\n');
      await _drain();
      final changes = world.service.paramsOf(
        world.handle,
        'textDocument/didChange',
      );
      expect(changes.map((c) => _map(c['textDocument'])['version']), [3, 4]);
      expect(changes.map((c) => c['contentChanges']), [
        [
          {'text': 'one\ntwo\n'},
        ],
        [
          {'text': 'three\n'},
        ],
      ]);
    });

    test('saves go to a server that asked for them; closing says so', () async {
      final world = await _World.ready();
      world.client.saved('a.py');
      world.client.saved('not-open.py');
      await _drain();
      expect(
        world.service.paramsOf(world.handle, 'textDocument/didSave').single,
        {
          'textDocument': {'uri': '$_rootUri/a.py'},
        },
      );
      world.client.close('a.py');
      await _drain();
      expect(world.methods.last, 'textDocument/didClose');
      expect(world.client.openPaths, isEmpty);
    });

    test('a server that takes whole texts gets them, and no saves', () async {
      final world = _World();
      world.service.capabilities = const {'textDocumentSync': 1};
      world.open('a.py', text: 'a\n');
      await _drain();
      world.client.applyEdit(
        'a.py',
        baseVersion: 1,
        version: 2,
        changes: [2, [0, 'b']],
      );
      world.client.saved('a.py');
      await _drain();
      expect(
        world.service
            .paramsOf(world.handle, 'textDocument/didChange')
            .single['contentChanges'],
        [
          {'text': 'a\nb'},
        ],
      );
      expect(world.methods, isNot(contains('textDocument/didSave')));
    });

    test('documents shown before the handshake go once it is done', () async {
      final world = _World();
      world.service.respond = (handle, method, params) => null;
      world
        ..open('a.py', text: 'a')
        ..open('b.py', text: 'b');
      await _drain();
      world.client.applyEdit(
        'a.py',
        baseVersion: 1,
        version: 2,
        changes: [1, [0, '!']],
      );
      expect(world.methods, ['initialize']);
      world.answerLast({'capabilities': world.service.capabilities});
      await _drain();
      expect(world.methods, [
        'initialize',
        'initialized',
        'textDocument/didOpen',
        'textDocument/didOpen',
      ]);
      expect(
        world.service
            .paramsOf(world.handle, 'textDocument/didOpen')
            .map((p) => _map(p['textDocument'])['text']),
        ['a!', 'b'],
      );
    });
  });

  group('requests', () {
    test('a request waits until the version the page names has gone out', () async {
      final world = await _World.ready(text: 'a\n');
      final asked = world.client.request(
        'textDocument/hover',
        {'position': 1},
        path: 'a.py',
        atVersion: 2,
      );
      await _drain();
      expect(world.methods, isNot(contains('textDocument/hover')));
      world.client.applyEdit(
        'a.py',
        baseVersion: 1,
        version: 2,
        changes: [2, [0, 'b']],
      );
      await _drain();
      final methods = world.methods;
      expect(methods.sublist(methods.length - 2), [
        'textDocument/didChange',
        'textDocument/hover',
      ]);
      world.answerLast({'contents': 'doc'});
      expect((await asked).valueOrNull, {'contents': 'doc'});
    });

    test('a version that never comes fails in time', () async {
      final world = await _World.ready();
      final asked = world.client.request(
        'textDocument/hover',
        null,
        path: 'a.py',
        atVersion: 9,
      );
      world.clock.advance(const Duration(seconds: 10));
      expect(await asked, _fails(LspProblem.timeout));
      expect(
        await world.client.request(
          'textDocument/hover',
          null,
          path: 'gone.py',
          atVersion: 1,
        ),
        _fails(LspProblem.badRequest),
      );
    });

    test('a completion is given up after 2 s, anything else after 10 s', () async {
      final world = await _World.ready();
      final completion = world.client.request('textDocument/completion', null);
      final hover = world.client.request('textDocument/hover', null);
      await _drain();
      world.clock.advance(const Duration(seconds: 2));
      expect(await completion, _fails(LspProblem.timeout));
      world.clock.advance(const Duration(seconds: 8));
      expect(await hover, _fails(LspProblem.timeout));
      await _drain();
      expect(
        world.service
            .paramsOf(world.handle, r'$/cancelRequest')
            .map((p) => p['id']),
        hasLength(2),
      );
    });

    test('while it starts or is off, a request fails at once', () async {
      final world = _World();
      expect(
        await world.client.request('textDocument/hover', null),
        _fails(LspProblem.stopped),
      );
      world.service.respond = (handle, method, params) => null;
      world.open('a.py');
      await _drain();
      expect(world.client.status.phase, LspPhase.starting);
      expect(
        await world.client.request('textDocument/hover', null),
        _fails(LspProblem.restarting),
      );
    });

    test("each request's time is kept, split into its stages", () async {
      final world = await _World.ready();
      final asked = world.client.request(
        'textDocument/completion',
        <String, Object?>{},
        path: 'a.py',
        atVersion: 1,
      );
      await _drain();
      world.clock.advance(const Duration(milliseconds: 30));
      world.answerLast(<Object?>[]);
      await asked;
      final timing = world.client.timings.last;
      expect(timing.server, LspServerId.pyright);
      expect(timing.method, 'textDocument/completion');
      expect(timing.outcome, 'ok');
      expect(timing.totalUs, 30000);
      expect(timing.queueUs, 0);
      expect(timing.serverUs, 30000);
      expect(timing.deliveryUs, 0);
      expect(world.client.timings.first.method, 'initialize');
    });
  });

  group("the server's news", () {
    test('diagnostics are routed by URI to their document, and go with it', () async {
      final world = await _World.ready();
      world
        ..deliver({
          'method': 'textDocument/publishDiagnostics',
          'params': {
            'uri': '$_rootUri/a.py',
            'version': 1,
            'diagnostics': [
              {
                'range': _range(0, 4, 0, 5),
                'severity': 1,
                'message': '"x" is not defined',
                'source': 'Pyright',
                'code': 'reportUndefinedVariable',
              },
              {'range': 'not a range', 'message': 'dropped'},
            ],
          },
        })
        ..deliver({
          'method': 'textDocument/publishDiagnostics',
          'params': {
            'uri': 'file:///usr/lib/python3.14/os.py',
            'diagnostics': [
              {'range': _range(0, 0, 0, 1), 'message': 'outside'},
            ],
          },
        });
      await _drain();
      expect(world.client.diagnostics.keys, ['a.py']);
      expect(world.client.diagnosticsOutside, 1);
      final published = world.diagnostics.single;
      expect(published.server, LspServerId.pyright);
      expect(published.path, 'a.py');
      expect(published.version, 1);
      final diagnostic = published.items.single;
      expect(diagnostic.severity, LspSeverity.error);
      expect(diagnostic.message, '"x" is not defined');
      expect(diagnostic.source, 'Pyright');
      expect(diagnostic.code, 'reportUndefinedVariable');
      expect(
        diagnostic.range,
        const LspRange(LspPosition(0, 4), LspPosition(0, 5)),
      );
      // Cleared by the server: an empty list.
      world.deliver({
        'method': 'textDocument/publishDiagnostics',
        'params': {'uri': '$_rootUri/a.py', 'diagnostics': <Object?>[]},
      });
      await _drain();
      expect(world.client.diagnostics, isEmpty);
      expect(world.diagnostics.last.items, isEmpty);
      // And when its tab closes.
      world.deliver({
        'method': 'textDocument/publishDiagnostics',
        'params': {
          'uri': '$_rootUri/a.py',
          'diagnostics': [
            {'range': _range(0, 0, 0, 1), 'message': 'again'},
          ],
        },
      });
      await _drain();
      world.client.close('a.py');
      await _drain();
      expect(world.client.diagnostics, isEmpty);
      expect(world.diagnostics.last.path, 'a.py');
      expect(world.diagnostics.last.items, isEmpty);
    });

    test('progress makes it analysing until the last one ends', () async {
      final world = await _World.ready();
      void progress(String token, String kind) => world.deliver({
        'method': r'$/progress',
        'params': {
          'token': token,
          'value': {'kind': kind, 'title': 'Analyzing'},
        },
      });
      progress('t1', 'begin');
      progress('t2', 'begin');
      await _drain();
      expect(world.client.status.phase, LspPhase.analysing);
      progress('t1', 'report');
      progress('t1', 'end');
      await _drain();
      expect(world.client.status.phase, LspPhase.analysing);
      progress('t2', 'end');
      await _drain();
      expect(world.client.status.phase, LspPhase.ready);
    });

    test('files changed go only to a server that registered for them, as it '
        'asked', () async {
      final world = await _World.ready();
      world.client.filesChanged(const [
        LspFileChange('b.py', LspFileChangeType.created),
      ]);
      await _drain();
      expect(world.methods, isNot(contains('workspace/didChangeWatchedFiles')));
      world.deliver({
        'id': 9,
        'method': 'client/registerCapability',
        'params': {
          'registrations': [
            {
              'id': 'w1',
              'method': 'workspace/didChangeWatchedFiles',
              'registerOptions': {
                'watchers': [
                  {'globPattern': '**/*.{py,pyi}'},
                  {
                    'globPattern': {
                      'baseUri': _rootUri,
                      'pattern': 'pyrightconfig.json',
                    },
                    'kind': 2,
                  },
                ],
              },
            },
          ],
        },
      });
      await _drain();
      world.client.filesChanged(const [
        LspFileChange('pkg/b.py', LspFileChangeType.created),
        LspFileChange('notes.txt', LspFileChangeType.changed),
        LspFileChange('pyrightconfig.json', LspFileChangeType.changed),
        LspFileChange('pyrightconfig.json', LspFileChangeType.deleted),
      ]);
      await _drain();
      expect(
        world.service
            .paramsOf(world.handle, 'workspace/didChangeWatchedFiles')
            .single['changes'],
        [
          {'uri': '$_rootUri/pkg/b.py', 'type': 1},
          {'uri': '$_rootUri/pyrightconfig.json', 'type': 2},
        ],
      );
      world.deliver({
        'id': 10,
        'method': 'client/unregisterCapability',
        'params': {
          'unregisterations': [
            {'id': 'w1', 'method': 'workspace/didChangeWatchedFiles'},
          ],
        },
      });
      await _drain();
      world.client.filesChanged(const [
        LspFileChange('pkg/c.py', LspFileChangeType.created),
      ]);
      await _drain();
      expect(
        world.service.paramsOf(world.handle, 'workspace/didChangeWatchedFiles'),
        hasLength(1),
      );
    });
  });

  group('restarts', () {
    test('a server that ends unasked starts again after 1 s with its '
        'documents; requests in flight fail as restarting', () async {
      final world = await _World.ready(text: 'a\n');
      final first = world.handle;
      final hover = world.client.request('textDocument/hover', null);
      await _drain();
      world.service.crash(first);
      expect(await hover, _fails(LspProblem.restarting));
      await _drain();
      expect(
        world.client.status,
        const LspStatus(
          LspPhase.restarting,
          reason: 'Pyright was ended by signal 9',
        ),
      );
      // Edits meanwhile are kept, and go with the document.
      world.client.applyEdit(
        'a.py',
        baseVersion: 1,
        version: 2,
        changes: [2, [0, 'b']],
      );
      world.clock.advance(const Duration(milliseconds: 999));
      await _drain();
      expect(world.service.starts, hasLength(1));
      world.clock.advance(const Duration(milliseconds: 1));
      await _drain();
      expect(world.service.starts, hasLength(2));
      expect(world.handle, isNot(first));
      expect(world.methods, [
        'initialize',
        'initialized',
        'textDocument/didOpen',
      ]);
      expect(
        world.service
            .paramsOf(world.handle, 'textDocument/didOpen')
            .single['textDocument'],
        {
          'uri': '$_rootUri/a.py',
          'languageId': 'python',
          'version': 2,
          'text': 'a\nb',
        },
      );
      expect(world.client.status.phase, LspPhase.ready);
      expect(world.statuses.map((s) => s.phase), [
        LspPhase.starting,
        LspPhase.ready,
        LspPhase.restarting,
        LspPhase.ready,
      ]);
    });

    test('the backoff is 1 s, 2 s, then 4 s; a fourth end within five '
        'minutes gives up, and only Restart starts it again', () async {
      final world = await _World.ready();
      for (final seconds in [1, 2, 4]) {
        world.service.crash(world.handle, end: LspEnd.exited, exitCode: 1);
        await _drain();
        expect(world.client.status.phase, LspPhase.restarting);
        final before = world.service.starts.length;
        world.clock.advance(Duration(milliseconds: seconds * 1000 - 1));
        await _drain();
        expect(world.service.starts, hasLength(before), reason: '$seconds s');
        world.clock.advance(const Duration(milliseconds: 1));
        await _drain();
        expect(world.service.starts, hasLength(before + 1), reason: '$seconds s');
        expect(world.client.status.phase, LspPhase.ready);
      }
      world.service.crash(world.handle, end: LspEnd.broken, signal: null);
      await _drain();
      expect(world.client.status.phase, LspPhase.off);
      expect(world.client.status.canRestart, isTrue);
      expect(world.client.status.reason, contains('4 times in 5 minutes'));
      world.clock.advance(const Duration(minutes: 10));
      world.open('b.py');
      await _drain();
      expect(world.service.starts, hasLength(4));
      await world.client.restart();
      await _drain();
      expect(world.service.starts, hasLength(5));
      expect(world.client.status, const LspStatus(LspPhase.ready));
      expect(
        world.service
            .paramsOf(world.handle, 'textDocument/didOpen')
            .map((p) => _map(p['textDocument'])['uri']),
        ['$_rootUri/a.py', '$_rootUri/b.py'],
      );
    });

    test('ends five minutes apart never give up', () async {
      final world = await _World.ready();
      for (var round = 0; round < 5; round++) {
        world.service.crash(world.handle);
        await _drain();
        world.clock.advance(const Duration(seconds: 1));
        await _drain();
        expect(world.client.status.phase, LspPhase.ready, reason: 'round $round');
        world.clock.advance(const Duration(minutes: 5));
      }
      expect(world.service.starts, hasLength(6));
    });

    test('a server stopped to free memory waits for the next document '
        'shown', () async {
      final world = await _World.ready(text: 'a\n');
      world.service.crash(world.handle, end: LspEnd.memory, signal: null);
      await _drain();
      expect(world.client.status.phase, LspPhase.off);
      expect(world.client.status.canRestart, isFalse);
      world.clock.advance(const Duration(minutes: 1));
      await _drain();
      expect(world.service.starts, hasLength(1));
      world.open('a.py', text: 'a\n');
      await _drain();
      expect(world.service.starts, hasLength(2));
      expect(world.client.status.phase, LspPhase.ready);
    });

    test('a start that cannot succeed by itself offers Restart', () async {
      final world = _World();
      world.service.failNextStart = const LspFailure(
        "The language server's files are damaged.",
        problem: LspProblem.damaged,
      );
      world.open('a.py');
      await _drain();
      expect(
        world.client.status,
        const LspStatus(
          LspPhase.off,
          reason: "The language server's files are damaged.",
          canRestart: true,
        ),
      );
      world.open('b.py');
      await _drain();
      expect(world.service.starts, hasLength(1));
      await world.client.restart();
      await _drain();
      expect(world.client.status.phase, LspPhase.ready);
    });

    test('no host, or a runtime not ready, is said; only the second may '
        'start later', () async {
      final none = _World();
      none.service.failNextStart = const LspFailure(
        'Language servers need Android.',
        problem: LspProblem.unavailable,
      );
      none.open('a.py');
      await _drain();
      expect(none.client.status.canRestart, isFalse);
      expect(none.client.status.phase, LspPhase.off);

      final waiting = _World();
      waiting.service.failNextStart = const LspFailure(
        'not ready',
        problem: LspProblem.notReady,
      );
      waiting.open('a.py');
      await _drain();
      expect(
        waiting.client.status,
        const LspStatus(LspPhase.off, reason: 'The Linux runtime is not ready'),
      );
      waiting.open('b.py');
      await _drain();
      expect(waiting.client.status.phase, LspPhase.ready);
    });

    test('one left running by an earlier client is stopped, and the start '
        'tried again', () async {
      final world = _World();
      world.service.failNextStart = const LspFailure(
        'That language server runs already.',
        problem: LspProblem.alreadyRunning,
        running: 42,
      );
      world.open('a.py');
      await _drain();
      expect(world.service.stops, [42]);
      expect(world.client.status.phase, LspPhase.restarting);
      world.clock.advance(const Duration(seconds: 1));
      await _drain();
      expect(world.client.status.phase, LspPhase.ready);
    });

    test('an initialize that fails or never answers ends the server, as a '
        'crash', () async {
      final world = _World();
      world.service.respond = (handle, method, params) => method == 'initialize'
          ? {
              'error': {'code': -32603, 'message': 'boom'},
            }
          : null;
      world.open('a.py');
      await _drain();
      final first = world.handle;
      expect(world.service.stops, [first]);
      expect(
        world.client.status,
        const LspStatus(
          LspPhase.restarting,
          reason: 'Pyright did not start: boom',
        ),
      );
      world.service.respond = (handle, method, params) => null;
      world.clock.advance(const Duration(seconds: 1));
      await _drain();
      expect(world.service.starts, hasLength(2));
      world.clock.advance(const Duration(seconds: 10));
      await _drain();
      expect(world.service.stops, [first, world.handle]);
      expect(world.client.status.phase, LspPhase.restarting);
      world.service.respond = null;
      world.clock.advance(const Duration(seconds: 2));
      await _drain();
      expect(world.client.status.phase, LspPhase.ready);
    });
  });

  group('stopping', () {
    test('ten minutes with no open document stop the server: shutdown, '
        'then exit', () async {
      final world = await _World.ready();
      world.client.close('a.py');
      await _drain();
      world.clock.advance(const Duration(minutes: 9, seconds: 59));
      await _drain();
      expect(world.client.status.phase, LspPhase.ready);
      world.clock.advance(const Duration(seconds: 1));
      await _drain();
      expect(world.methods.sublist(world.methods.length - 2), [
        'shutdown',
        'exit',
      ]);
      expect(
        world.client.status,
        const LspStatus(
          LspPhase.off,
          reason: 'Stopped after 10 minutes without an open file',
        ),
      );
      expect(world.service.running, isEmpty);
      expect(world.service.stops, isEmpty);
      expect(world.clock.pending, 0);
      // Shown again: a new server, with the document.
      world.open('a.py', text: 'b\n', version: 4);
      await _drain();
      expect(world.service.starts, hasLength(2));
      expect(world.client.status.phase, LspPhase.ready);
    });

    test('a document shown within the ten minutes keeps it running', () async {
      final world = await _World.ready();
      world.client.close('a.py');
      world.clock.advance(const Duration(minutes: 5));
      world.open('b.py');
      await _drain();
      world.clock.advance(const Duration(minutes: 30));
      await _drain();
      expect(world.client.status.phase, LspPhase.ready);
      expect(world.methods, isNot(contains('shutdown')));
    });

    test('a server that does not exit after exit is stopped through the '
        'host', () async {
      final world = await _World.ready();
      final handle = world.handle;
      world.service.exitAfterExit = false;
      final stopping = world.client.stop(reason: 'Asked');
      await _drain();
      expect(world.methods.sublist(world.methods.length - 2), [
        'shutdown',
        'exit',
      ]);
      expect(world.service.stops, isEmpty);
      world.clock.advance(const Duration(seconds: 2));
      await _drain();
      expect(world.service.stops, [handle]);
      await stopping;
      expect(world.client.status, const LspStatus(LspPhase.off, reason: 'Asked'));
      // Its exit was asked for: not a crash, no restart.
      world.clock.advance(const Duration(minutes: 1));
      await _drain();
      expect(world.service.starts, hasLength(1));
    });

    test('disposing stops the server through the host and closes the '
        'streams', () async {
      final world = await _World.ready();
      final handle = world.handle;
      final pending = world.client.request('textDocument/hover', null);
      await world.client.dispose();
      expect(await pending, _fails(LspProblem.stopped));
      await _drain();
      expect(world.service.stops, [handle]);
      expect(world.clock.pending, 0);
    });

    test("another server's end is not this one's", () async {
      final world = await _World.ready();
      // The same host for both: a TypeScript server starts, and crashes.
      final shared = LanguageClient(
        server: LspServerId.typescript,
        workspace: const LspWorkspace.project('demo'),
        service: world.service,
        clock: world.clock,
      );
      shared.open('b.ts', language: 'typescript', version: 1, text: '');
      await _drain();
      world.service.crash(world.service.latest);
      await _drain();
      expect(world.client.status.phase, LspPhase.ready);
      expect(shared.status.phase, LspPhase.restarting);
      await shared.dispose();
    });
  });
}
