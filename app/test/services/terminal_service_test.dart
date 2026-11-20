/// The terminal's Dart side (Phase 5 W2): the Pigeon client against mocked
/// host channels (a start and its refusals, input, sizes, credit, attach,
/// ends, End all, the host's batches and changes, no host at all), the
/// honest fake, and the host's codes.
library;

import 'dart:typed_data';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/terminal/terminal_models.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/fakes.dart';
import 'package:codeforge/services/terminal/native/pigeon_terminal_service.dart';
import 'package:codeforge/services/terminal/native/terminal_api.g.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _fails(TerminalProblem problem) => isA<Err<Object?>>().having(
  (e) => e.failure,
  'failure',
  isA<TerminalFailure>().having((f) => f.problem, 'problem', problem),
);

TerminalInfoMessage _info(
  int id, {
  String state = 'running',
  int? exitCode,
  String? failure,
}) => TerminalInfoMessage(
  id: id,
  label: 'bash',
  state: state,
  rows: 24,
  columns: 80,
  received: 0,
  leftovers: 0,
  remaining: 0,
  exitCode: exitCode,
  failure: failure,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const prefix = 'dev.flutter.pigeon.codeforge.TerminalApi';
  const events = 'dev.flutter.pigeon.codeforge.TerminalEvents';
  const methods = [
    'start',
    'sessions',
    'write',
    'resize',
    'acknowledge',
    'attach',
    'detach',
    'end',
    'endAll',
    'remove',
  ];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = TerminalApi.pigeonChannelCodec;

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
      TerminalEvents.pigeonChannelCodec.encodeMessage(args),
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
    test('starts a session, then hears its output and its exit', () async {
      answer('start', (args) => TerminalStartMessage(session: _info(7)));
      final service = PigeonTerminalService();
      final output = <TerminalOutput>[];
      final changes = <TerminalInfo>[];
      final hearOutput = service.output.listen(output.add);
      final hearChanges = service.changes.listen(changes.add);

      final started = await service.start(
        const TerminalSpec(
          project: 'demo',
          environment: {'EDITOR': 'nano'},
          rows: 30,
          columns: 100,
        ),
      );
      final session = started.orThrow;
      expect(session.id, 7);
      expect(session.state, TerminalSessionState.running);
      expect(session.isRunning, isTrue);
      final spec = asked.single[1]! as TerminalSpecMessage;
      expect(spec.project, 'demo');
      expect(spec.program, isNull);
      expect(spec.arguments, isEmpty);
      expect(spec.environment, {'EDITOR': 'nano'});
      expect([spec.rows, spec.columns], [30, 100]);

      await notice('output', [7, 0, Uint8List.fromList('hi\r\n'.codeUnits)]);
      expect(output.single.sessionId, 7);
      expect(output.single.offset, 0);
      expect(String.fromCharCodes(output.single.bytes), 'hi\r\n');
      expect(output.single.end, 4);

      await notice('changed', [_info(7, state: 'exited', failure: 'ended')]);
      expect(changes.single.state, TerminalSessionState.exited);
      expect(changes.single.isRunning, isFalse);
      expect(changes.single.problem, TerminalProblem.ended);

      await hearOutput.cancel();
      await hearChanges.cancel();
      await service.dispose();
    });

    test('a refused start is a typed failure that says why', () async {
      answer(
        'start',
        (args) => TerminalStartMessage(
          failure: 'too_many',
          detail: '8 terminal sessions are running already',
        ),
      );
      final service = PigeonTerminalService();
      final refused = await service.start(const TerminalSpec());
      expect(refused, _fails(TerminalProblem.tooMany));
      expect(
        (refused as Err<TerminalInfo>).failure.message,
        '8 terminal sessions are running already',
      );
      await service.dispose();
    });

    test('input, sizes, credit and ends reach the host', () async {
      answer('write', (args) => null);
      answer('resize', (args) => 'not_running');
      answer('acknowledge', (args) => null);
      answer('detach', (args) => null);
      answer('end', (args) => null);
      answer('remove', (args) => 'still_running');
      answer('endAll', (args) => 0);
      final service = PigeonTerminalService();

      final typed = Uint8List.fromList('ls\r'.codeUnits);
      expect(await service.write(3, typed), isA<Ok<void>>());
      expect(
        await service.resize(3, rows: 40, columns: 120),
        _fails(TerminalProblem.notRunning),
      );
      await service.acknowledge(3, 2048);
      await service.detach(3);
      expect(await service.end(3), isA<Ok<void>>());
      expect(await service.remove(3), _fails(TerminalProblem.stillRunning));
      expect((await service.endAll()).orThrow, 0);

      expect(asked.map((call) => call.first), [
        'write',
        'resize',
        'acknowledge',
        'detach',
        'end',
        'remove',
        'endAll',
      ]);
      expect(asked[0][1], 3);
      expect(asked[0][2], typed);
      expect(asked[1].sublist(1), [3, 40, 120]);
      expect(asked[2].sublist(1), [3, 2048]);
      await service.dispose();
    });

    test('lists sessions and attaches to one with its replay', () async {
      answer(
        'sessions',
        (args) => <TerminalInfoMessage>[
          _info(1),
          _info(2, state: 'exited', exitCode: 3),
        ],
      );
      answer(
        'attach',
        (args) => args.first == 2
            ? TerminalReplayMessage(
                offset: 100,
                bytes: Uint8List.fromList(r'$ '.codeUnits),
              )
            : TerminalReplayMessage(
                offset: 0,
                bytes: Uint8List(0),
                failure: 'no_such_session',
              ),
      );
      final service = PigeonTerminalService();
      final sessions = (await service.sessions()).orThrow;
      expect(sessions.map((s) => s.id), [1, 2]);
      expect(sessions.last.exitCode, 3);
      expect(sessions.last.problem, isNull);

      final replay = (await service.attach(2)).orThrow;
      expect(replay.offset, 100);
      expect(replay.end, 102);
      expect(await service.attach(9), _fails(TerminalProblem.noSuchSession));
      await service.dispose();
    });

    test('without a host every call fails as unavailable', () async {
      final service = PigeonTerminalService();
      expect(
        await service.start(const TerminalSpec()),
        _fails(TerminalProblem.unavailable),
      );
      expect(
        await service.write(1, Uint8List(1)),
        _fails(TerminalProblem.unavailable),
      );
      expect(await service.endAll(), _fails(TerminalProblem.unavailable));
      // Credit and detaching never throw, host or not.
      await service.acknowledge(1, 10);
      await service.detach(1);
      await service.dispose();
    });
  });

  group('the honest fake', () {
    test('is unavailable, and so is every call', () async {
      final terminal = FakeTerminalService();
      expect(terminal.availability, TerminalAvailability.unavailable);
      expect(
        await terminal.start(const TerminalSpec()),
        _fails(TerminalProblem.unavailable),
      );
      expect(
        await terminal.write(1, Uint8List(1)),
        _fails(TerminalProblem.unavailable),
      );
      expect((await terminal.sessions()).orThrow, isEmpty);
      expect((await terminal.endAll()).orThrow, 0);
      expect(await terminal.output.isEmpty, isTrue);
      expect(await terminal.changes.isEmpty, isTrue);
    });
  });

  group("the host's codes", () {
    test("each of TerminalSession.kt's codes has its problem", () {
      const codes = {
        'not_ready': TerminalProblem.notReady,
        'bad_request': TerminalProblem.badRequest,
        'not_found': TerminalProblem.notFound,
        'too_many': TerminalProblem.tooMany,
        'cannot_start': TerminalProblem.cannotStart,
        'terminal_failed': TerminalProblem.terminalFailed,
        'launch_failed': TerminalProblem.launchFailed,
        'ended': TerminalProblem.ended,
        'signaled': TerminalProblem.signaled,
        'lost': TerminalProblem.lost,
        'no_such_session': TerminalProblem.noSuchSession,
        'not_running': TerminalProblem.notRunning,
        'input_full': TerminalProblem.inputFull,
        'still_running': TerminalProblem.stillRunning,
        'system': TerminalProblem.system,
      };
      for (final MapEntry(:key, :value) in codes.entries) {
        expect(TerminalProblem.fromCode(key), value, reason: key);
        expect(terminalFailureFrom(key, null).message, isNotEmpty);
      }
      expect(
        TerminalProblem.fromCode('something_new'),
        TerminalProblem.unknown,
      );
      expect(TerminalProblem.fromCode(null), TerminalProblem.unknown);
      expect(
        TerminalSessionState.fromCode('starting'),
        TerminalSessionState.starting,
      );
      expect(TerminalSessionState.fromCode('odd'), TerminalSessionState.exited);
    });
  });
}
