/// A TerminalService that is available and does what a test scripts
/// (Phase 5 W3): sessions start at once with increasing ids; what the app
/// writes, resizes, acknowledges, ends and removes is recorded; the test
/// makes sessions print ([emitOutput]) and end ([exit]). The real host is
/// covered by the JVM and instrumented TerminalSessionTest (W2).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/terminal/terminal_models.dart';
import 'package:codeforge/services/contracts.dart';

final class ScriptedTerminalService implements TerminalService {
  ScriptedTerminalService({this.firstId = 1});

  final int firstId;
  late int _nextId = firstId;

  final StreamController<TerminalOutput> _output =
      StreamController<TerminalOutput>.broadcast();
  final StreamController<TerminalInfo> _changes =
      StreamController<TerminalInfo>.broadcast();

  /// The sessions, by id.
  final Map<int, TerminalInfo> infos = {};

  /// Every spec the app started, in order.
  final List<TerminalSpec> specs = [];

  /// What the app sent each session, in order.
  final Map<int, List<Uint8List>> writes = {};

  /// Every resize: rows and columns, per session, in order.
  final List<({int id, int rows, int columns})> resizes = [];

  /// Every acknowledged offset, per session, in order.
  final Map<int, List<int>> acknowledged = {};
  final List<int> ended = [];
  final List<int> removed = [];
  int endAllCalls = 0;

  /// What `attach` replays for a session (empty unless a test sets it).
  final Map<int, Uint8List> buffers = {};

  /// The next start fails with this, when set.
  TerminalFailure? failNextStart;

  /// Each session's byte count so far: the next print's offset.
  final Map<int, int> _offsets = {};

  @override
  TerminalAvailability get availability => TerminalAvailability.available;

  @override
  String get unavailableReason => '';

  @override
  Stream<TerminalOutput> get output => _output.stream;

  @override
  Stream<TerminalInfo> get changes => _changes.stream;

  /// What session [id] wrote, as text.
  String written(int id) =>
      utf8.decode([for (final chunk in writes[id] ?? <Uint8List>[]) ...chunk]);

  @override
  Future<Result<TerminalInfo>> start(TerminalSpec spec) async {
    specs.add(spec);
    final failure = failNextStart;
    if (failure != null) {
      failNextStart = null;
      return Err(failure);
    }
    final id = _nextId++;
    final info = TerminalInfo(
      id: id,
      label: spec.label ?? 'bash',
      state: TerminalSessionState.running,
      rows: spec.rows,
      columns: spec.columns,
      received: 0,
    );
    infos[id] = info;
    // Output may have come before the start returned.
    _offsets.putIfAbsent(id, () => 0);
    return Ok(info);
  }

  /// Session [id] prints [bytes] (or [text]).
  void emitOutput(int id, {String? text, List<int>? bytes}) {
    final data = Uint8List.fromList(bytes ?? utf8.encode(text!));
    final offset = _offsets[id] ?? 0;
    _offsets[id] = offset + data.length;
    _output.add(TerminalOutput(id, offset, data));
  }

  /// Session [id]'s program exits with [code], or is ended by [signal].
  void exit(int id, {int? code = 0, int? signal}) {
    final info = infos[id]!;
    final exited = TerminalInfo(
      id: id,
      label: info.label,
      state: TerminalSessionState.exited,
      rows: info.rows,
      columns: info.columns,
      received: _offsets[id] ?? 0,
      exitCode: signal == null ? code : null,
      signal: signal,
    );
    infos[id] = exited;
    _changes.add(exited);
  }

  @override
  Future<Result<List<TerminalInfo>>> sessions() async => Ok([...infos.values]);

  @override
  Future<Result<void>> write(int id, Uint8List bytes) async {
    if (!infos.containsKey(id)) {
      return const Err(
        TerminalFailure(
          'That terminal is gone.',
          problem: TerminalProblem.noSuchSession,
        ),
      );
    }
    (writes[id] ??= []).add(bytes);
    return const Ok(null);
  }

  @override
  Future<Result<void>> resize(
    int id, {
    required int rows,
    required int columns,
  }) async {
    resizes.add((id: id, rows: rows, columns: columns));
    return const Ok(null);
  }

  @override
  Future<void> acknowledge(int id, int offset) async {
    (acknowledged[id] ??= []).add(offset);
  }

  @override
  Future<Result<TerminalReplay>> attach(int id) async {
    final buffer = buffers[id] ?? Uint8List(0);
    final end = _offsets[id] ?? buffer.length;
    return Ok(TerminalReplay(end - buffer.length, buffer));
  }

  /// The sessions detached, in order (Phase 5 W5: views let go).
  final List<int> detached = [];

  @override
  Future<void> detach(int id) async {
    detached.add(id);
  }

  @override
  Future<Result<void>> end(int id) async {
    ended.add(id);
    if (infos[id]?.isRunning ?? false) {
      final info = infos[id]!;
      final exited = TerminalInfo(
        id: id,
        label: info.label,
        state: TerminalSessionState.exited,
        rows: info.rows,
        columns: info.columns,
        received: _offsets[id] ?? 0,
        problem: TerminalProblem.ended,
      );
      infos[id] = exited;
      _changes.add(exited);
    }
    return const Ok(null);
  }

  @override
  Future<Result<int>> endAll() async {
    endAllCalls += 1;
    for (final id in [...infos.keys]) {
      if (infos[id]!.isRunning) {
        await end(id);
      }
    }
    return const Ok(0);
  }

  @override
  Future<Result<void>> remove(int id) async {
    final info = infos[id];
    if (info == null) {
      return const Err(
        TerminalFailure(
          'That terminal is gone.',
          problem: TerminalProblem.noSuchSession,
        ),
      );
    }
    if (info.isRunning) {
      return const Err(
        TerminalFailure(
          'That terminal still runs.',
          problem: TerminalProblem.stillRunning,
        ),
      );
    }
    infos.remove(id);
    removed.add(id);
    return const Ok(null);
  }

  Future<void> dispose() async {
    await _output.close();
    await _changes.close();
  }
}
