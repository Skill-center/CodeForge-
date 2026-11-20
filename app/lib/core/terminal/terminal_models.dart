/// Terminal sessions as the app sees them (Phase 5 W2;
/// docs/TERMINAL_ARCHITECTURE.md §1): what to start, what a session is now,
/// and what it writes. Pure Dart: the Pigeon client
/// (services/terminal/native/) turns the host's messages into these.
library;

import 'dart:typed_data';

import '../errors/failure.dart';

/// What a terminal session should be.
final class TerminalSpec {
  const TerminalSpec({
    this.project,
    this.copy,
    this.program,
    this.arguments = const [],
    this.environment = const {},
    this.rows = 24,
    this.columns = 80,
    this.bufferBytes,
    this.label,
  });

  /// A project's folder name, which the host resolves in its projects'
  /// folder itself: never a path. The runtime's home when null.
  final String? project;

  /// A folder's run copy by its id (the folder workspace's), which the
  /// host resolves in its copies' folder itself (Phase 5 W4, ADR-0013);
  /// never set with [project].
  final String? copy;

  /// A program in the runtime's bin, by name. Null is the shell: bash,
  /// interactive, with CodeForge's rc file.
  final String? program;

  /// The program's arguments; the shell's are CodeForge's own.
  final List<String> arguments;

  /// Variables to add. The host refuses the runtime's own and any LD_*.
  final Map<String, String> environment;

  final int rows;
  final int columns;

  /// The output the session keeps while no view is attached (1 MiB when
  /// null).
  final int? bufferBytes;

  /// The session's name; the program's when null.
  final String? label;
}

/// Where a terminal session is in its life.
enum TerminalSessionState {
  starting('starting'),
  running('running'),
  exited('exited');

  const TerminalSessionState(this.code);

  final String code;

  /// The state for a host's [code]; an unknown one counts as [exited].
  static TerminalSessionState fromCode(String code) {
    for (final state in values) {
      if (state.code == code) {
        return state;
      }
    }
    return exited;
  }
}

/// One terminal session, as the host last reported it.
final class TerminalInfo {
  const TerminalInfo({
    required this.id,
    required this.label,
    required this.state,
    required this.rows,
    required this.columns,
    required this.received,
    this.exitCode,
    this.signal,
    this.problem,
    this.detail,
    this.leftovers = 0,
    this.remaining = 0,
  });

  final int id;
  final String label;
  final TerminalSessionState state;
  final int rows;
  final int columns;

  /// Every byte the session has written so far.
  final int received;

  /// The shell's exit code, when it exited by itself.
  final int? exitCode;

  /// The signal that ended the shell, when one did.
  final int? signal;

  /// How it ended when not by its shell's own exit; null while it runs and
  /// after a plain exit.
  final TerminalProblem? problem;

  final String? detail;

  /// Processes ended with it: what the shell left, or its whole tree.
  final int leftovers;

  /// Processes that could not be ended: 0 unless the system refused.
  final int remaining;

  bool get isRunning => state != TerminalSessionState.exited;
}

/// Output a session wrote: [bytes], from [offset] in its stream.
final class TerminalOutput {
  const TerminalOutput(this.sessionId, this.offset, this.bytes);

  final int sessionId;
  final int offset;
  final Uint8List bytes;

  /// The offset after these bytes: what a view acknowledges once it has
  /// drawn them.
  int get end => offset + bytes.length;
}

/// What a view gets when it attaches: the session's buffer, from [offset].
final class TerminalReplay {
  const TerminalReplay(this.offset, this.bytes);

  final int offset;
  final Uint8List bytes;

  /// The offset after the replay: the next output starts there.
  int get end => offset + bytes.length;
}
