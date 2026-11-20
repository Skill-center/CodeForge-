/// The Dart side of the terminal protocol v1 against the shared fixtures in
/// editor/test/fixtures/terminal/: the page runs the same files under
/// vitest (editor/test/terminal_protocol.test.ts), so both ends provably
/// accept and reject exactly the same messages.
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/terminal/terminal_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// `flutter test` runs with the package root (app/) as working directory.
const String _editorRoot = '../editor';

List<(String, Map<String, Object?>)> _fixtures(String dir) {
  final files =
      Directory('$_editorRoot/test/fixtures/$dir')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files)
      (
        file.uri.pathSegments.last,
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
      ),
  ];
}

String _describe(ParseResult result) => switch (result) {
  ParsedMessage(:final message) => 'accepted ${message.type}',
  RejectedMessage(:final code, :final reason) => 'rejected $code: $reason',
};

/// The string items of `export const <name> = [...] as const;` in
/// protocol.ts.
List<String> _tsList(String source, String name) {
  final match = RegExp(
    'export const $name = \\[([^\\]]*)\\]',
  ).firstMatch(source);
  if (match == null) {
    throw StateError('$name not found in protocol.ts');
  }
  return [
    for (final item in RegExp("'([^']*)'").allMatches(match.group(1)!))
      item.group(1)!,
  ];
}

/// The message types in validate.ts: the keys, two spaces in, of
/// `const <name>: Record<string, Check> = {...};`.
Set<String> _tsTypes(String source, String name) {
  final start = source.indexOf('const $name: Record<string, Check> = {');
  if (start < 0) {
    throw StateError('$name not found in validate.ts');
  }
  final block = source.substring(start, source.indexOf('\n};', start));
  final key = RegExp("^  '?([A-Za-z.]+)'?:", multiLine: true);
  return {for (final match in key.allMatches(block)) match.group(1)!};
}

void main() {
  group('valid terminal fixtures are accepted', () {
    for (final (direction, dir) in [
      (TerminalDirection.hostToTerminal, 'terminal/valid/host_to_terminal'),
      (TerminalDirection.terminalToHost, 'terminal/valid/terminal_to_host'),
    ]) {
      final fixtures = _fixtures(dir);
      test('$dir is not empty', () => expect(fixtures, isNotEmpty));
      for (final (name, fixture) in fixtures) {
        test('$dir/$name', () {
          final message = fixture['message'];
          final asObject = validateTerminalMessage(message, direction);
          expect(asObject, isA<ParsedMessage>(), reason: _describe(asObject));
          final asWire = parseTerminalMessage(jsonEncode(message), direction);
          expect(asWire, isA<ParsedMessage>(), reason: _describe(asWire));
          // Encoding a parsed message reproduces an accepted message.
          final reencoded = (asWire as ParsedMessage).message.encode();
          expect(
            parseTerminalMessage(reencoded, direction),
            isA<ParsedMessage>(),
            reason: reencoded,
          );
        });
      }
    }
  });

  group('invalid terminal fixtures are rejected with their code', () {
    final fixtures = _fixtures('terminal/invalid');
    test('fixtures exist', () => expect(fixtures, isNotEmpty));
    for (final (name, fixture) in fixtures) {
      test('$name → ${fixture['error']}', () {
        final direction = TerminalDirection.fromWireName(
          fixture['direction']! as String,
        )!;
        final raw = fixture['raw'];
        final result = raw is String
            ? parseTerminalMessage(raw, direction)
            : validateTerminalMessage(fixture['message'], direction);
        expect(result, isA<RejectedMessage>(), reason: _describe(result));
        expect((result as RejectedMessage).code, fixture['error']);
      });
    }
  });

  group('the protocol mirrors editor/src/terminal/', () {
    final validate = File(
      '$_editorRoot/src/terminal/validate.ts',
    ).readAsStringSync();
    final protocol = File(
      '$_editorRoot/src/terminal/protocol.ts',
    ).readAsStringSync();

    for (final (direction, table, dir) in [
      (
        TerminalDirection.hostToTerminal,
        'HOST_TO_TERMINAL',
        'terminal/valid/host_to_terminal',
      ),
      (
        TerminalDirection.terminalToHost,
        'TERMINAL_TO_HOST',
        'terminal/valid/terminal_to_host',
      ),
    ]) {
      test('${direction.wireName} types equal validate.ts', () {
        expect(terminalMessageTypes(direction), _tsTypes(validate, table));
      });

      test('${direction.wireName} fixtures cover every type', () {
        final covered = {
          for (final (_, fixture) in _fixtures(dir))
            (fixture['message']! as Map<String, Object?>)['type']! as String,
        };
        expect(covered, terminalMessageTypes(direction));
      });
    }

    test('the lists equal protocol.ts', () {
      expect(terminalKeyNames, _tsList(protocol, 'KEY_NAMES'));
      expect(terminalErrorCodes, _tsList(protocol, 'TERMINAL_ERROR_CODES'));
      expect(terminalLogLevels, _tsList(protocol, 'LOG_LEVELS'));
      expect(terminalThemeColors, _tsList(protocol, 'THEME_COLORS'));
      expect(terminalRenderers, _tsList(protocol, 'RENDERERS'));
    });

    test('the limits equal protocol.ts', () {
      int limit(String name) {
        final match = RegExp(
          'export const $name = ([^;]+);',
        ).firstMatch(protocol);
        if (match == null) {
          throw StateError('$name not found in protocol.ts');
        }
        // `8 * 1024 * 1024`, `MAX_PASTE_CHARS + 64` or a plain number.
        final expression = match
            .group(1)!
            .replaceAll('MAX_PASTE_CHARS', '$maxPasteChars');
        final sum = expression.split('+').map((term) {
          return term
              .split('*')
              .map((factor) => int.parse(factor.trim()))
              .fold(1, (a, b) => a * b);
        });
        return sum.fold(0, (a, b) => a + b);
      }

      expect(maxTerminalMessageChars, limit('MAX_TERMINAL_MESSAGE_CHARS'));
      expect(maxWriteChars, limit('MAX_WRITE_CHARS'));
      expect(maxPasteChars, limit('MAX_PASTE_CHARS'));
      expect(maxInputChars, limit('MAX_INPUT_CHARS'));
      expect(maxTerminalDimension, limit('MAX_DIMENSION'));
      expect(maxSnapshotScrollback, limit('MAX_SNAPSHOT_SCROLLBACK'));
      expect(maxTerminalScrollback, limit('MAX_SCROLLBACK'));
      expect(maxProbeSamples, limit('MAX_PROBE_SAMPLES'));
      expect(maxProbeGapMs, limit('MAX_PROBE_GAP_MS'));
      expect(maxProbeMarkChars, limit('MAX_PROBE_MARK_CHARS'));
    });
  });

  test('a refused message keeps its id, so the refusal can be answered', () {
    final result = parseTerminalMessage(
      '{"v":1,"id":"h42","type":"session.open","payload":{}}',
      TerminalDirection.hostToTerminal,
    );
    expect(result, isA<RejectedMessage>());
    expect((result as RejectedMessage).id, 'h42');
    expect(result.code, 'bad_payload');
  });

  test('a message over the limit is refused before decoding', () {
    final result = parseTerminalMessage(
      ' ' * (maxTerminalMessageChars + 1),
      TerminalDirection.hostToTerminal,
    );
    expect((result as RejectedMessage).code, 'too_large');
  });
}
