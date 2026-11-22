/// The language servers' host from Dart (Phase 6 W4): the Pigeon client
/// against mocked host channels (a start with where the server works, its
/// refusals, a send answered once written, a stop, the running servers, the
/// host's messages with when it read them, and its exits), no host at all,
/// the honest fake, and the host's codes in the app's words.
library;

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/services/fakes.dart';
import 'package:codeforge/services/lsp/native/lsp_api.g.dart';
import 'package:codeforge/services/lsp/native/pigeon_lsp_service.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _fails(LspProblem problem) => isA<Err<Object?>>().having(
  (e) => e.failure,
  'failure',
  isA<LspFailure>().having((f) => f.problem, 'problem', problem),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const prefix = 'dev.flutter.pigeon.codeforge.LspApi';
  const events = 'dev.flutter.pigeon.codeforge.LspEvents';
  const methods = ['start', 'send', 'stop', 'servers'];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = LspApi.pigeonChannelCodec;

  /// What each host method was asked, in order: its name, then its
  /// arguments.
  late List<List<Object?>> asked;

  void answer(String method, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$prefix.$method', (message) async {
      final args =
          codec.decodeMessage(message) as List<Object?>? ?? const <Object?>[];
      asked.add([method, ...args]);
      return codec.encodeMessage(<Object?>[reply(args)]);
    });
  }

  Future<void> notice(String event, List<Object?> args) async {
    await messenger.handlePlatformMessage(
      '$events.$event',
      LspEvents.pigeonChannelCodec.encodeMessage(args),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() => asked = []);

  tearDown(() {
    for (final method in methods) {
      messenger.setMockMessageHandler('$prefix.$method', null);
    }
  });

  group('the Pigeon client', () {
    test('starts a server by its id in a named workspace, and hears where '
        'it works', () async {
      answer(
        'start',
        (args) => LspStartMessage(
          handle: 4,
          root: '/data/data/dev.codeforge.app/files/workspaces/demo',
          bin: '/rt/usr/bin',
          serverDirectory: '/rt/codeforge/lsp/pyright',
        ),
      );
      final service = PigeonLspService();
      final started = (await service.start(
        LspServerId.pyright,
        const LspWorkspace.project('demo'),
      )).orThrow;
      expect(started.handle, 4);
      expect(
        started.root,
        '/data/data/dev.codeforge.app/files/workspaces/demo',
      );
      expect(started.bin, '/rt/usr/bin');
      expect(started.serverDirectory, '/rt/codeforge/lsp/pyright');
      expect(asked.single, ['start', 'pyright', 'demo', null]);
      await service.dispose();
    });

    test("a refusal carries the host's code, its words, and the server "
        'already running', () async {
      answer(
        'start',
        (args) => LspStartMessage(
          failure: 'already_running',
          detail: 'the pyright server runs already',
          running: 3,
        ),
      );
      final service = PigeonLspService();
      final refused = await service.start(
        LspServerId.pyright,
        const LspWorkspace.copy('f3a9'),
      );
      expect(refused, _fails(LspProblem.alreadyRunning));
      final failure = refused.failureOrNull! as LspFailure;
      expect(failure.running, 3);
      expect(failure.message, 'the pyright server runs already');
      expect(asked.single, ['start', 'pyright', null, 'f3a9']);
      answer('start', (args) => LspStartMessage(failure: 'damaged'));
      final damaged = await service.start(
        LspServerId.typescript,
        const LspWorkspace.project('demo'),
      );
      expect(damaged, _fails(LspProblem.damaged));
      expect(
        damaged.failureOrNull!.message,
        "The language server's files are damaged.",
      );
      await service.dispose();
    });

    test('a send answers once written, with when; or why not', () async {
      answer(
        'send',
        (args) => args[0] == 1
            ? LspSendMessage(writtenUs: 12345)
            : LspSendMessage(failure: 'not_running'),
      );
      final service = PigeonLspService();
      final written = await service.send(1, '{"jsonrpc":"2.0"}');
      expect(written.valueOrNull?.writtenUs, 12345);
      expect(asked.first, ['send', 1, '{"jsonrpc":"2.0"}']);
      expect(await service.send(2, '{}'), _fails(LspProblem.notRunning));
      await service.dispose();
    });

    test('stops a server, and lists those that run', () async {
      answer('stop', (args) => args[0] == 1 ? null : 'no_such_server');
      answer(
        'servers',
        (args) => [
          LspServerMessage(
            handle: 1,
            server: 'pyright',
            project: 'demo',
            startedAtMs: 5,
            installMs: 0,
            received: 3,
            sent: 4,
            pssKib: 150000,
            rssKib: 200000,
            processes: 2,
          ),
        ],
      );
      final service = PigeonLspService();
      expect((await service.stop(1)).isOk, isTrue);
      expect(await service.stop(9), _fails(LspProblem.noSuchServer));
      final server = (await service.servers()).orThrow.single;
      expect(server.handle, 1);
      expect(server.server, 'pyright');
      expect(server.project, 'demo');
      expect(server.copy, isNull);
      expect(server.received, 3);
      expect(server.sent, 4);
      expect(server.pssKib, 150000);
      expect(server.processes, 2);
      await service.dispose();
    });

    test(
      "hears the host's messages, with when it read them, and its exits",
      () async {
        final service = PigeonLspService();
        final messages = <LspIncoming>[];
        final exits = <LspExit>[];
        final hearMessages = service.messages.listen(messages.add);
        final hearExits = service.exits.listen(exits.add);
        await notice('received', [4, '{"jsonrpc":"2.0","method":"x"}', 777]);
        await notice('exited', [
          LspExitMessage(
            handle: 4,
            server: 'pyright',
            end: 'signaled',
            signal: 9,
            stderr: 'the tail',
            leftovers: 1,
            remaining: 0,
          ),
        ]);
        expect(messages.single.handle, 4);
        expect(messages.single.json, '{"jsonrpc":"2.0","method":"x"}');
        expect(messages.single.readUs, 777);
        final exit = exits.single;
        expect(exit.handle, 4);
        expect(exit.server, 'pyright');
        expect(exit.end, LspEnd.signaled);
        expect(exit.signal, 9);
        expect(exit.exitCode, isNull);
        expect(exit.stderr, 'the tail');
        expect(exit.leftovers, 1);
        await hearMessages.cancel();
        await hearExits.cancel();
        await service.dispose();
      },
    );

    test('with no host every call fails as unavailable', () async {
      final service = PigeonLspService();
      expect(
        await service.start(
          LspServerId.typescript,
          const LspWorkspace.project('demo'),
        ),
        _fails(LspProblem.unavailable),
      );
      expect(await service.send(1, '{}'), _fails(LspProblem.unavailable));
      expect(await service.stop(1), _fails(LspProblem.unavailable));
      expect(await service.servers(), _fails(LspProblem.unavailable));
      await service.dispose();
    });
  });

  test('the honest fake has no servers to run', () async {
    final fake = FakeLspService();
    expect(fake.available, isFalse);
    expect(
      await fake.start(LspServerId.pyright, const LspWorkspace.project('demo')),
      _fails(LspProblem.unavailable),
    );
    expect(await fake.send(1, '{}'), _fails(LspProblem.unavailable));
    expect((await fake.servers()).valueOrNull, isEmpty);
  });

  test("every host code has the app's own words", () {
    for (final code in [
      'not_ready',
      'bad_request',
      'not_in_apk',
      'damaged',
      'storage',
      'too_many',
      'already_running',
      'launch_failed',
      'no_such_server',
      'not_running',
      'queue_full',
    ]) {
      final failure = lspFailureFrom(code, null);
      expect(failure.problem.code, code);
      expect(failure.message, isNot(contains('failed (')), reason: code);
    }
    expect(lspFailureFrom('a_new_code', null).problem, LspProblem.unknown);
    expect(LspEnd.fromCode('memory'), LspEnd.memory);
    expect(LspEnd.fromCode('nonsense'), LspEnd.lost);
    expect(LspServerId.fromId('typescript'), LspServerId.typescript);
    expect(LspServerId.forLanguage('tsx'), LspServerId.typescript);
    expect(LspServerId.forLanguage('python'), LspServerId.pyright);
    expect(LspServerId.forLanguage('rust'), isNull);
  });
}
