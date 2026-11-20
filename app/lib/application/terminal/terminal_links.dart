/// A `file:line` the user tapped in a terminal's output (Phase 5 W4), for
/// the workbench to open at its line: the terminal controller resolves the
/// link (core/terminal/file_links.dart) and asks here; the workbench
/// listens. Nothing here builds the terminal itself.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A workspace path and its line to open, or what went wrong.
final class FileLinkRequest {
  const FileLinkRequest({
    required this.serial,
    this.path,
    this.line = 1,
    this.column,
    this.problem,
  });

  /// Tells two taps on the same link apart.
  final int serial;
  final String? path;
  final int line;
  final int? column;

  /// Why the link leads nowhere here, for the workbench to say.
  final String? problem;
}

final class TerminalLinkRequests extends Notifier<FileLinkRequest?> {
  int _serial = 0;

  @override
  FileLinkRequest? build() => null;

  void open(String path, {required int line, int? column}) => state =
      FileLinkRequest(serial: ++_serial, path: path, line: line, column: column);

  void problem(String message) =>
      state = FileLinkRequest(serial: ++_serial, problem: message);
}

final terminalLinkRequestsProvider =
    NotifierProvider<TerminalLinkRequests, FileLinkRequest?>(
      TerminalLinkRequests.new,
    );
