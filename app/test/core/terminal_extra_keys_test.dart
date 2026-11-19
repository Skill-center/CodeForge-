/// The terminal's extra-keys row (Phase 5 W3): the plan's keys, each one
/// sending what the terminal protocol allows.
library;

import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/terminal/extra_keys.dart';
import 'package:codeforge/core/terminal/terminal_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the row starts with the plan’s keys, in order', () {
    expect(
      [for (final key in terminalExtraKeys.take(11)) key.id],
      [
        'esc',
        'ctrl',
        'alt',
        'tab',
        'left',
        'up',
        'down',
        'right',
        'pipe',
        'tilde',
        'slash',
      ],
    );
  });

  test('every key has its own id and a name a screen reader can say', () {
    final ids = [for (final key in terminalExtraKeys) key.id];
    expect(ids.toSet(), hasLength(ids.length));
    for (final key in terminalExtraKeys) {
      expect(key.semanticLabel, isNotEmpty, reason: key.id);
      expect(key.label, isNotEmpty, reason: key.id);
    }
  });

  test('every sending key sends what session.key accepts', () {
    for (final key in terminalExtraKeys) {
      if (key.kind != ExtraKeyKind.key) {
        expect(key.key, isNull, reason: key.id);
        continue;
      }
      final result = validateTerminalMessage({
        'v': 1,
        'id': 'h1',
        'type': 'session.key',
        'payload': {'sessionId': 1, 'key': key.key},
      }, TerminalDirection.hostToTerminal);
      expect(result, isA<ParsedMessage>(), reason: key.id);
    }
  });

  test('Ctrl and Alt are the latching keys', () {
    expect(
      [
        for (final key in terminalExtraKeys)
          if (key.kind != ExtraKeyKind.key) key.id,
      ],
      ['ctrl', 'alt'],
    );
  });
}
