/// Terminal protocol, version 1 (Phase 5 W3): the Dart mirror of
/// editor/src/terminal/ (protocol.ts and validate.ts), the contract between
/// the app and the terminal page (xterm.js).
///
/// Both sides validate every message against the same rules, and the shared
/// fixtures in editor/test/fixtures/terminal/ prove they agree: the page runs
/// them in vitest, the app in test/core/terminal_protocol_test.dart. A rule
/// changed on one side must change on the other, with a fixture.
///
/// - The envelope is the editor protocol's (`{"v": 1, "id", "type",
///   "payload"}`, [BridgeMessage]); unknown versions, types and fields are
///   rejected.
/// - Every host request gets exactly one `response`, except an accepted
///   `session.write`: the page acknowledges it with `session.ack` once
///   xterm.js has parsed it, which is the session's credit.
/// - Output and input travel as text: the host decodes each session's UTF-8
///   and holds back a sequence split between two batches.
library;

import 'dart:convert';

import '../editor/protocol.dart'
    show BridgeMessage, ParseResult, ParsedMessage, RejectedMessage;
import '../protocol/checks.dart';

/// Version carried in every envelope (`v`).
const int terminalProtocolVersion = 1;

/// Upper bound for one serialized message, in UTF-16 code units.
const int maxTerminalMessageChars = 8 * 1024 * 1024;

/// The most a `session.write` carries: the host's window is 256 KiB.
const int maxWriteChars = 1024 * 1024;

/// The most a pasted text may hold; its UTF-8 fits the host's input queue.
const int maxPasteChars = 256 * 1024;

/// The most one `session.input` carries: a paste, bracketed.
const int maxInputChars = maxPasteChars + 64;

/// Rows and columns, as the host's sessions allow them.
const int maxTerminalDimension = 999;

/// The most scrollback lines a snapshot returns.
const int maxSnapshotScrollback = 1000;

/// The most scrollback a terminal may be configured to keep.
const int maxTerminalScrollback = 50000;

/// Keys the extra-keys row sends by name (`session.key`); a key may also be
/// one printable ASCII character.
const List<String> terminalKeyNames = [
  'escape',
  'tab',
  'enter',
  'backspace',
  'up',
  'down',
  'left',
  'right',
  'home',
  'end',
  'pageUp',
  'pageDown',
  'insert',
  'delete',
];

const List<String> terminalLogLevels = ['debug', 'info', 'warn', 'error'];

const List<String> terminalErrorCodes = [
  'bad_json',
  'bad_envelope',
  'unsupported_version',
  'unknown_type',
  'bad_payload',
  'too_large',
  'unknown_session',
  'session_exists',
  'internal',
];

/// The colours of a `terminal.configure` theme, besides `dark`.
const List<String> terminalThemeColors = [
  'background',
  'foreground',
  'cursor',
  'cursorAccent',
  'selection',
  'black',
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
  'brightBlack',
  'brightRed',
  'brightGreen',
  'brightYellow',
  'brightBlue',
  'brightMagenta',
  'brightCyan',
  'brightWhite',
];

/// Which way a message travels; each direction has its own type table.
enum TerminalDirection {
  hostToTerminal('host-to-terminal'),
  terminalToHost('terminal-to-host');

  const TerminalDirection(this.wireName);

  /// The name the shared fixtures and diagnostics use.
  final String wireName;

  static TerminalDirection? fromWireName(String name) {
    for (final direction in values) {
      if (direction.wireName == name) {
        return direction;
      }
    }
    return null;
  }
}

// ------------------------------------------------------------------- rules

final Check _sessionId = intCheck(min: 1);
final Check _seq = intCheck(min: 0);
final Check _dimension = intCheck(min: 1, max: maxTerminalDimension);
final Check _color = stringCheck(pattern: colorPattern);

/// A key name, or one printable ASCII character.
String? _key(Object? value, String path) {
  if (value is! String) {
    return '$path must be a string';
  }
  if (terminalKeyNames.contains(value)) {
    return null;
  }
  if (value.length == 1) {
    final code = value.codeUnitAt(0);
    if (code >= 0x20 && code <= 0x7e) {
      return null;
    }
  }
  return '$path must be a key name or one printable ASCII character';
}

final Check _theme = objectCheck({
  'dark': boolCheck,
  for (final name in terminalThemeColors) name: _color,
});

final Map<String, Check> _hostToTerminal = {
  'terminal.configure': objectCheck({}, {
    'theme': _theme,
    'fontSize': numberCheck(min: 8, max: 40),
    'scrollback': intCheck(min: 0, max: maxTerminalScrollback),
  }),
  'terminal.focus': objectCheck({'focused': boolCheck}),
  'terminal.modifiers': objectCheck({'ctrl': boolCheck, 'alt': boolCheck}),
  'session.open': objectCheck(
    {'sessionId': _sessionId},
    {'activate': boolCheck},
  ),
  'session.activate': objectCheck({'sessionId': _sessionId}),
  'session.close': objectCheck({'sessionId': _sessionId}),
  'session.write': objectCheck({
    'sessionId': _sessionId,
    'seq': _seq,
    'data': stringCheck(max: maxWriteChars),
  }),
  'session.clear': objectCheck({'sessionId': _sessionId}),
  'session.paste': objectCheck({
    'sessionId': _sessionId,
    'text': stringCheck(max: maxPasteChars),
  }),
  'session.key': objectCheck(
    {'sessionId': _sessionId, 'key': _key},
    {'ctrl': boolCheck, 'alt': boolCheck, 'shift': boolCheck},
  ),
  'session.select': objectCheck({
    'sessionId': _sessionId,
    'action': oneOfCheck(const ['all', 'none']),
  }),
  'session.copy': objectCheck({'sessionId': _sessionId}),
  'session.snapshot': objectCheck(
    {'sessionId': _sessionId},
    {'scrollback': intCheck(min: 0, max: maxSnapshotScrollback)},
  ),
};

final Check _responseOk = objectCheck(
  {'re': stringCheck(pattern: idPattern), 'ok': boolCheck},
  {'result': anyValueCheck},
);

final Check _responseError = objectCheck({
  're': stringCheck(pattern: idPattern),
  'ok': boolCheck,
  'error': objectCheck({
    'code': oneOfCheck(terminalErrorCodes),
    'message': stringCheck(max: 2000),
  }),
});

String? _responsePayload(Object? value, String path) {
  if (value is! Map<String, Object?>) {
    return '$path must be an object';
  }
  if (value['ok'] == true) {
    return _responseOk(value, path);
  }
  if (value['ok'] == false) {
    return _responseError(value, path);
  }
  return '$path.ok must be a boolean';
}

final Map<String, Check> _terminalToHost = {
  'terminal.ready': objectCheck({
    'protocol': intCheck(min: 1),
    'engine': stringCheck(min: 1, max: 64),
    'engineVersion': stringCheck(min: 1, max: 64),
  }),
  'terminal.focus': objectCheck({'focused': boolCheck}),
  'terminal.modifiers': objectCheck({'ctrl': boolCheck, 'alt': boolCheck}),
  'terminal.log': objectCheck({
    'level': oneOfCheck(terminalLogLevels),
    'message': stringCheck(max: 4000),
  }),
  'session.input': objectCheck(
    {'sessionId': _sessionId, 'data': stringCheck(min: 1, max: maxInputChars)},
    {'binary': boolCheck},
  ),
  'session.resized': objectCheck({
    'sessionId': _sessionId,
    'cols': _dimension,
    'rows': _dimension,
  }),
  'session.ack': objectCheck({'sessionId': _sessionId, 'seq': _seq}),
  'session.title': objectCheck({
    'sessionId': _sessionId,
    'title': stringCheck(max: 256),
  }),
  'session.bell': objectCheck({'sessionId': _sessionId}),
  'session.link': objectCheck({
    'sessionId': _sessionId,
    'text': stringCheck(min: 1, max: 4096),
  }),
  'session.selection': objectCheck({
    'sessionId': _sessionId,
    'active': boolCheck,
  }),
  'response': _responsePayload,
};

/// The message types accepted travelling in [direction]: the validator's
/// table, which the contract tests hold equal to the page's
/// (editor/src/terminal/validate.ts).
Set<String> terminalMessageTypes(TerminalDirection direction) {
  final table = switch (direction) {
    TerminalDirection.hostToTerminal => _hostToTerminal,
    TerminalDirection.terminalToHost => _terminalToHost,
  };
  return table.keys.toSet();
}

const List<String> _envelopeKeys = ['v', 'id', 'type', 'payload'];

/// Validates an already decoded [value] as a message travelling in
/// [direction]. The checks run in the same order as validate.ts, so both
/// sides report the same error code for the same message.
ParseResult validateTerminalMessage(
  Object? value,
  TerminalDirection direction,
) {
  if (value is! Map<String, Object?>) {
    return const RejectedMessage('bad_envelope', 'message must be an object');
  }
  // Recover the id early so a rejection can still be answered.
  final rawId = value['id'];
  final id = rawId is String && idPattern.hasMatch(rawId) ? rawId : null;
  for (final key in value.keys) {
    if (!_envelopeKeys.contains(key)) {
      return RejectedMessage('bad_envelope', '$key is not allowed', id: id);
    }
  }
  if (id == null) {
    return const RejectedMessage(
      'bad_envelope',
      'id must match [A-Za-z0-9_.:-]{1,64}',
    );
  }
  if (value['v'] != terminalProtocolVersion) {
    return RejectedMessage(
      'unsupported_version',
      'v must be $terminalProtocolVersion',
      id: id,
    );
  }
  final type = value['type'];
  if (type is! String) {
    return RejectedMessage('bad_envelope', 'type must be a string', id: id);
  }
  final table = switch (direction) {
    TerminalDirection.hostToTerminal => _hostToTerminal,
    TerminalDirection.terminalToHost => _terminalToHost,
  };
  final check = table[type];
  if (check == null) {
    return RejectedMessage(
      'unknown_type',
      'unknown ${direction.wireName} type: $type',
      id: id,
    );
  }
  if (!value.containsKey('payload')) {
    return RejectedMessage('bad_envelope', 'payload is required', id: id);
  }
  final payload = value['payload'];
  final error = check(payload, 'payload');
  if (error != null) {
    return RejectedMessage('bad_payload', error, id: id);
  }
  return ParsedMessage(
    BridgeMessage(id: id, type: type, payload: payload as Map<String, Object?>),
  );
}

/// Decodes and validates one serialized message travelling in [direction].
ParseResult parseTerminalMessage(String raw, TerminalDirection direction) {
  if (raw.length > maxTerminalMessageChars) {
    return const RejectedMessage(
      'too_large',
      'message exceeds $maxTerminalMessageChars characters',
    );
  }
  final Object? value;
  try {
    value = jsonDecode(raw);
  } on FormatException {
    return const RejectedMessage('bad_json', 'message is not valid JSON');
  }
  return validateTerminalMessage(value, direction);
}
