/// The Dart side of protocol v1 against the shared fixtures in
/// editor/test/fixtures/ — the page runs the same files under vitest, so
/// both ends provably accept, reject and apply exactly the same things.
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeforge/core/editor/change_set.dart';
import 'package:codeforge/core/editor/protocol.dart';
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

/// The `result` of a `response` fixture's payload.
Object? _resultOf(Object? message) =>
    ((message! as Map<String, Object?>)['payload']!
        as Map<String, Object?>)['result'];

String _describe(ParseResult result) => switch (result) {
  ParsedMessage(:final message) => 'accepted ${message.type}',
  RejectedMessage(:final code, :final reason) => 'rejected $code: $reason',
};

/// The string items of `export const <name> = [...]` in types.ts (a type
/// annotation before the `=` is allowed).
List<String> _tsList(String source, String name) {
  final match = RegExp(
    'export const $name(?:: [^=]+)? = \\[([^\\]]*)\\]',
  ).firstMatch(source);
  if (match == null) {
    throw StateError('$name not found in types.ts');
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
  group('valid fixtures are accepted', () {
    for (final (direction, dir) in [
      (MessageDirection.hostToEditor, 'protocol/valid/host_to_editor'),
      (MessageDirection.editorToHost, 'protocol/valid/editor_to_host'),
    ]) {
      final fixtures = _fixtures(dir);
      test('$dir is not empty', () => expect(fixtures, isNotEmpty));
      for (final (name, fixture) in fixtures) {
        test('$dir/$name', () {
          final message = fixture['message'];
          final asObject = validateMessage(message, direction);
          expect(asObject, isA<ParsedMessage>(), reason: _describe(asObject));
          final asWire = parseMessage(jsonEncode(message), direction);
          expect(asWire, isA<ParsedMessage>(), reason: _describe(asWire));
          // Encoding a parsed message reproduces an accepted message.
          final reencoded = (asWire as ParsedMessage).message.encode();
          expect(
            parseMessage(reencoded, direction),
            isA<ParsedMessage>(),
            reason: reencoded,
          );
          // An answer to a page request (Phase 6 W5): its result too.
          final answers = fixture['answers'];
          if (answers is String) {
            expect(
              validatePageResult(answers, _resultOf(message)),
              isNull,
              reason: name,
            );
          }
        });
      }
    }
  });

  group('invalid fixtures are rejected with their code', () {
    final fixtures = _fixtures('protocol/invalid');
    test('fixtures exist', () => expect(fixtures, isNotEmpty));
    for (final (name, fixture) in fixtures) {
      test('$name → ${fixture['error']}', () {
        final direction = MessageDirection.fromWireName(
          fixture['direction']! as String,
        )!;
        final raw = fixture['raw'];
        final result = raw is String
            ? parseMessage(raw, direction)
            : validateMessage(fixture['message'], direction);
        final answers = fixture['answers'];
        if (answers is String) {
          // The envelope passes; the result for that request does not.
          expect(result, isA<ParsedMessage>(), reason: _describe(result));
          expect(fixture['error'], 'bad_payload');
          expect(
            validatePageResult(answers, _resultOf(fixture['message'])),
            isNotNull,
          );
          return;
        }
        expect(result, isA<RejectedMessage>(), reason: _describe(result));
        expect((result as RejectedMessage).code, fixture['error']);
      });
    }
  });

  group('change set fixtures apply identically', () {
    final fixtures = _fixtures('changes');
    test('fixtures exist', () => expect(fixtures, isNotEmpty));
    for (final (name, fixture) in fixtures) {
      test(name, () {
        final before = fixture['before']! as String;
        final after = fixture['after']! as String;
        final changes = fixture['changes']! as List<Object?>;
        expect(applyChanges(before, changes), after);
        expect(changeLengths(changes), (
          before: before.length,
          after: after.length,
        ));
      });
    }
  });

  group('message types mirror editor/src/protocol/validate.ts', () {
    final source = File(
      '$_editorRoot/src/protocol/validate.ts',
    ).readAsStringSync();

    for (final (direction, table, dir) in [
      (
        MessageDirection.hostToEditor,
        'HOST_TO_EDITOR',
        'protocol/valid/host_to_editor',
      ),
      (
        MessageDirection.editorToHost,
        'EDITOR_TO_HOST',
        'protocol/valid/editor_to_host',
      ),
    ]) {
      test('${direction.wireName}: both sides accept the same types', () {
        final page = _tsTypes(source, table);
        expect(page, isNotEmpty);
        expect(messageTypes(direction), page);
      });

      test('${direction.wireName}: every type has a valid fixture', () {
        final covered = {
          for (final (_, fixture) in _fixtures(dir))
            (fixture['message']! as Map<String, Object?>)['type'],
        };
        expect(covered, messageTypes(direction));
      });
    }
  });

  group('page requests mirror validate.ts (Phase 6 W5)', () {
    final validate = File(
      '$_editorRoot/src/protocol/validate.ts',
    ).readAsStringSync();
    final types = File('$_editorRoot/src/protocol/types.ts').readAsStringSync();

    test('both sides check the same results', () {
      expect(pageResultTypes, _tsTypes(validate, 'PAGE_RESULTS'));
      expect(pageResultTypes, pageRequestTypes.toSet());
      expect(pageRequestTypes, _tsList(types, 'PAGE_REQUEST_TYPES'));
    });

    test('every page request is sent and answered in a fixture', () {
      final sent = {
        for (final (_, fixture) in _fixtures('protocol/valid/editor_to_host'))
          (fixture['message']! as Map<String, Object?>)['type'],
      };
      final answered = {
        for (final (_, fixture) in _fixtures('protocol/valid/host_to_editor'))
          fixture['answers'],
      };
      for (final type in pageRequestTypes) {
        expect(sent, contains(type));
        expect(answered, contains(type));
      }
    });

    test('caps: 200 completion items, 1000 diagnostics', () {
      expect(types, contains('MAX_COMPLETION_ITEMS = $maxCompletionItems;'));
      expect(types, contains('MAX_DIAGNOSTICS = $maxDiagnostics;'));
      expect(
        types,
        contains('MAX_EDITED_DOCUMENTS = $maxEditedDocuments;'),
      );
      expect(types, contains('MAX_DOCUMENT_EDITS = $maxDocumentEdits;'));
      List<Map<String, Object?>> items(int n) => [
        for (var i = 0; i < n; i++) {'label': 'item$i'},
      ];
      Map<String, Object?> answer(int n) => {
        'resultId': 'c1',
        'incomplete': true,
        'items': items(n),
      };
      expect(validatePageResult('lsp.complete', answer(200)), isNull);
      expect(validatePageResult('lsp.complete', answer(201)), isNotNull);
    });
  });

  group('constants mirror editor/src/protocol/types.ts', () {
    final source = File(
      '$_editorRoot/src/protocol/types.ts',
    ).readAsStringSync();

    test('version and size cap', () {
      expect(source, contains('PROTOCOL_VERSION = $protocolVersion;'));
      expect(source, contains('MAX_MESSAGE_CHARS = 32 * 1024 * 1024;'));
      expect(maxMessageChars, 32 * 1024 * 1024);
    });

    test('value lists', () {
      expect(editorLanguageIds, _tsList(source, 'LANGUAGE_IDS'));
      expect(editorCommands, _tsList(source, 'EDITOR_COMMANDS'));
      expect(appShortcuts, _tsList(source, 'APP_SHORTCUTS'));
      expect(editorLogLevels, _tsList(source, 'LOG_LEVELS'));
      expect(protocolErrorCodes, _tsList(source, 'ERROR_CODES'));
      // Phase 6 W5.
      expect(diagnosticSeverities, _tsList(source, 'DIAGNOSTIC_SEVERITIES'));
      expect(diagnosticTags, _tsList(source, 'DIAGNOSTIC_TAGS'));
      expect(completionKinds, _tsList(source, 'COMPLETION_KINDS'));
      expect(completionTriggers, _tsList(source, 'COMPLETION_TRIGGERS'));
      expect(markupKinds, _tsList(source, 'MARKUP_KINDS'));
    });
  });

  group('validator details', () {
    Map<String, Object?> replace(Object? version) => {
      'v': 1,
      'id': 'h1',
      'type': 'doc.replace',
      'payload': {'docId': 'd1', 'text': 'x', 'version': version},
    };

    test('integers may arrive as whole doubles, as JSON numbers do', () {
      final result = validateMessage(
        replace(3.0),
        MessageDirection.hostToEditor,
      );
      expect(result, isA<ParsedMessage>(), reason: _describe(result));
      expect((result as ParsedMessage).message.payload.integer('version'), 3);
    });

    test('fractions, unsafe integers and negatives are not integers', () {
      for (final bad in [1.5, 9007199254740992, -1, 'one', null]) {
        final result = validateMessage(
          replace(bad),
          MessageDirection.hostToEditor,
        );
        expect(result, isA<RejectedMessage>(), reason: '$bad');
        expect((result as RejectedMessage).code, 'bad_payload');
        // A usable id survives, so the sender can be told what went wrong.
        expect(result.id, 'h1');
      }
    });

    test('oversized messages are refused before parsing', () {
      final result = parseMessage(
        ' ' * (maxMessageChars + 1),
        MessageDirection.editorToHost,
      );
      expect(result, isA<RejectedMessage>());
      expect((result as RejectedMessage).code, 'too_large');
    });

    test('the same type is only valid in its own direction', () {
      const message = {
        'v': 1,
        'id': 'h1',
        'type': 'doc.flush',
        'payload': <String, Object?>{},
      };
      expect(
        validateMessage(message, MessageDirection.hostToEditor),
        isA<ParsedMessage>(),
      );
      final reversed = validateMessage(message, MessageDirection.editorToHost);
      expect((reversed as RejectedMessage).code, 'unknown_type');
    });

    test('direction wire names round-trip', () {
      for (final direction in MessageDirection.values) {
        expect(MessageDirection.fromWireName(direction.wireName), direction);
      }
      expect(MessageDirection.fromWireName('sideways'), isNull);
    });
  });

  group('applyChanges refuses what does not fit', () {
    test('a change set longer than the document', () {
      expect(
        () => applyChanges('abc', [4]),
        throwsA(isA<ChangeApplyException>()),
      );
    });

    test('a change set shorter than the document', () {
      expect(
        () => applyChanges('abc', [2]),
        throwsA(isA<ChangeApplyException>()),
      );
    });

    test('malformed parts', () {
      for (final changes in <List<Object?>>[
        [<Object?>[]],
        [
          ['x'],
        ],
        [
          [1, 2],
        ],
        ['3'],
        [-1, 4],
      ]) {
        expect(
          () => applyChanges('abc', changes),
          throwsA(isA<ChangeApplyException>()),
          reason: '$changes',
        );
      }
    });

    test('an insertion at the start keeps the rest', () {
      expect(
        applyChanges('abc', [
          [0, 'x', 'y'],
          3,
        ]),
        'x\nyabc',
      );
    });
  });
}
