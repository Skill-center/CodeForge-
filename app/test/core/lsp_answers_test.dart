/// The servers' answers, as the editor draws them (Phase 6 W5,
/// core/lsp/lsp_answers.dart): completion lists trimmed to the word typed
/// and to 200 in the server's order, their edits as offsets, snippets as
/// text, documentation and hover text, definitions, what a rename would
/// change, and diagnostics.
library;

import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/lsp/lsp_answers.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _range(int sl, int sc, int el, int ec) => {
  'start': {'line': sl, 'character': sc},
  'end': {'line': el, 'character': ec},
};

void main() {
  group('completion', () {
    const text = 'import os\nos.pa';

    test('keeps what matches the word typed, in the server order', () {
      final answer = completionAnswer(
        {
          'isIncomplete': false,
          'items': [
            {'label': 'pathsep', 'sortText': 'b', 'kind': 6},
            {'label': 'getcwd', 'sortText': 'a', 'kind': 3},
            {'label': 'path', 'sortText': 'a', 'kind': 9, 'detail': 'module'},
          ],
        },
        text: text,
        pos: text.length,
        resolvable: true,
      );
      expect([for (final i in answer.items) i['label']], ['path', 'pathsep']);
      expect(answer.items.first, {
        'label': 'path',
        'kind': 'namespace',
        'detail': 'module',
        'sortText': 'a',
        'resolvable': true,
      });
      expect(answer.incomplete, isFalse);
      expect(answer.total, 3);
      expect(answer.raw.first['label'], 'path');
    });

    test('trims to 200 and says the list is incomplete', () {
      final items = [
        for (var i = 0; i < 450; i++)
          {'label': 'name${i.toString().padLeft(3, '0')}'},
      ];
      final answer = completionAnswer(
        items,
        text: 'na',
        pos: 2,
        resolvable: false,
      );
      expect(answer.items, hasLength(maxCompletionItems));
      expect(answer.items.first['label'], 'name000');
      expect(answer.incomplete, isTrue);
      expect(
        validatePageResult('lsp.complete', {
          'resultId': 'c1',
          'items': answer.items,
          'incomplete': answer.incomplete,
        }),
        isNull,
      );
    });

    test('turns edits into offsets, snippets into text, and keeps imports', () {
      const source = 'x = 1\nGre';
      final answer = completionAnswer(
        [
          {
            'label': 'Greeter',
            'kind': 7,
            'insertTextFormat': 2,
            'textEdit': {
              'range': _range(1, 0, 1, 3),
              'newText': r'Greeter(${1:name})$0',
            },
            'additionalTextEdits': [
              {
                'range': _range(0, 0, 0, 0),
                'newText': 'from people import Greeter\r\n',
              },
            ],
          },
          {
            // InsertReplaceEdit: the insert range.
            'label': 'greet',
            'textEdit': {
              'insert': _range(1, 0, 1, 3),
              'replace': _range(1, 0, 1, 3),
              'newText': 'greet',
            },
            'tags': [1],
          },
        ],
        text: source,
        pos: source.length,
        resolvable: false,
      );
      expect(answer.items[0], {
        'label': 'Greeter',
        'kind': 'class',
        'edit': {'from': 6, 'to': 9, 'insert': 'Greeter(name)'},
        'additionalEdits': [
          {'from': 0, 'to': 0, 'insert': 'from people import Greeter\n'},
        ],
      });
      expect(answer.items[1]['edit'], {'from': 6, 'to': 9, 'insert': 'greet'});
      expect(answer.items[1]['deprecated'], isTrue);
    });

    test("takes the list's default range (LSP 3.17's itemDefaults)", () {
      const source = 'pr';
      final answer = completionAnswer(
        {
          'isIncomplete': true,
          'itemDefaults': {'editRange': _range(0, 0, 0, 2)},
          'items': [
            {'label': 'print', 'textEditText': 'print'},
          ],
        },
        text: source,
        pos: 2,
        resolvable: false,
      );
      expect(answer.items.single['edit'], {
        'from': 0,
        'to': 2,
        'insert': 'print',
      });
      expect(answer.incomplete, isTrue);
    });

    test('skips items without a label, and maps every kind to an icon', () {
      final answer = completionAnswer(
        [
          {'kind': 3},
          {'label': ''},
          {'label': 'ok'},
        ],
        text: '',
        pos: 0,
        resolvable: false,
      );
      expect([for (final i in answer.items) i['label']], ['ok']);
      for (var kind = 1; kind <= 25; kind++) {
        expect(
          completionKinds,
          contains(completionKindOf(kind)),
          reason: '$kind',
        );
      }
      expect(completionKindOf(99), isNull);
    });

    test('the word before the cursor and the fuzzy match', () {
      expect(wordBefore('os.pa', 5), 'pa');
      expect(wordBefore('os.', 3), '');
      expect(wordBefore(r'$el', 3), r'$el');
      expect(fuzzyMatches('gt', 'greet'), isTrue);
      expect(fuzzyMatches('GR', 'greet'), isTrue);
      expect(fuzzyMatches('tg', 'greet'), isFalse);
      expect(fuzzyMatches('', 'x'), isTrue);
    });

    test('snippets become the text they insert', () {
      expect(snippetToPlainText(r'greet(${1:name})$0'), 'greet(name)');
      expect(
        snippetToPlainText(r'${1|a,b|} ${2:${3:inner}} \$x $TM_FILENAME'),
        r'a inner $x ',
      );
      expect(snippetToPlainText(r'price: $'), r'price: $');
    });
  });

  group('documentation and hover', () {
    test('resolve: detail, documentation and the import, as offsets', () {
      const text = 'gre';
      final answer = resolveAnswer({
        'label': 'greet',
        'detail': 'function greet(): void',
        'documentation': {'kind': 'markdown', 'value': 'Says hello.'},
        'additionalTextEdits': [
          {
            'range': _range(0, 0, 0, 0),
            'newText': "import { greet } from './people';\n",
          },
        ],
      }, text: text);
      expect(answer, {
        'detail': 'function greet(): void',
        'documentation': {'kind': 'markdown', 'value': 'Says hello.'},
        'additionalEdits': [
          {'from': 0, 'to': 0, 'insert': "import { greet } from './people';\n"},
        ],
      });
      expect(validatePageResult('lsp.resolve', answer), isNull);
      expect(resolveAnswer(null, text: text), isEmpty);
    });

    test('markup: MarkupContent, MarkedStrings and lists of them', () {
      expect(markupOf({'kind': 'plaintext', 'value': 'a\r\nb'}), {
        'kind': 'plaintext',
        'value': 'a\nb',
      });
      expect(markupOf({'language': 'python', 'value': 'def f(): ...'}), {
        'kind': 'markdown',
        'value': '```python\ndef f(): ...\n```',
      });
      expect(markupOf(['one', 'two'])?['value'], 'one\n\n---\n\ntwo');
      expect(markupOf(''), isNull);
      expect(markupOf(null), isNull);
    });

    test('hover: the text, and its range as offsets', () {
      const text = 'print(greet)\n';
      final answer = hoverAnswer({
        'contents': {
          'kind': 'markdown',
          'value': '```python\n(function) def greet() -> str\n```',
        },
        'range': _range(0, 6, 0, 11),
      }, text: text);
      expect(answer['from'], 6);
      expect(answer['to'], 11);
      expect(validatePageResult('lsp.hover', answer), isNull);
      expect(hoverAnswer(null, text: text), isEmpty);
      expect(hoverAnswer({'contents': ''}, text: text), isEmpty);
    });
  });

  group('definition and rename', () {
    test('locations: one, a list, or links', () {
      final one = locationsOf({
        'uri': 'file:///a.py',
        'range': _range(1, 2, 1, 5),
      });
      expect(one.single.uri, 'file:///a.py');
      expect(one.single.range.start, const LspPosition(1, 2));
      final links = locationsOf([
        {
          'targetUri': 'file:///b.ts',
          'targetRange': _range(0, 0, 9, 0),
          'targetSelectionRange': _range(3, 4, 3, 9),
        },
      ]);
      expect(links.single.range.start, const LspPosition(3, 4));
      expect(locationsOf(null), isEmpty);
      expect(locationsOf([]), isEmpty);
    });

    test('prepareRename: a range, a range with a placeholder, or the word', () {
      expect(prepareRenameOf(_range(0, 4, 0, 9)).range?.start.character, 4);
      final named = prepareRenameOf({
        'range': _range(0, 4, 0, 9),
        'placeholder': 'greet',
      });
      expect(named.placeholder, 'greet');
      final word = prepareRenameOf({'defaultBehavior': true});
      expect(word.renameable, isTrue);
      expect(word.range, isNull);
      expect(prepareRenameOf(null).renameable, isFalse);
      expect(wordAt('print(greet)', 8), (from: 6, to: 11));
      expect(wordAt('a + b', 2), isNull);
    });
  });

  group('diagnostics', () {
    LspDiagnostic d(
      LspSeverity severity, {
      List<LspDiagnosticTag> tags = const [],
    }) => LspDiagnostic(
      range: const LspRange(LspPosition(1, 0), LspPosition(1, 99)),
      severity: severity,
      message: severity.name,
      source: 'Pyright',
      code: 'x',
      tags: tags,
    );

    test('as the page draws them: offsets, severities, tags', () {
      const text = 'import os\nprint(greet)\n';
      final items = diagnosticItems([
        d(LspSeverity.error),
        d(LspSeverity.hint, tags: [LspDiagnosticTag.unnecessary]),
      ], text);
      expect(items.first, {
        'from': 10,
        'to': 22,
        'severity': 'error',
        'message': 'error',
        'source': 'Pyright',
        'code': 'x',
      });
      expect(items.last['tags'], ['unnecessary']);
      expect(items.last['severity'], 'hint');
    });

    test('at most 1000, errors first', () {
      final many = [
        for (var i = 0; i < 1200; i++) d(LspSeverity.hint),
        d(LspSeverity.error),
      ];
      final items = diagnosticItems(many, 'a\nb\n');
      expect(items, hasLength(maxDiagnostics));
      expect(items.first['severity'], 'error');
    });

    test("LSP's tags are read", () {
      final parsed = LspDiagnostic.fromJson({
        'range': _range(0, 0, 0, 1),
        'message': 'x',
        'tags': [1, 2, 7],
      });
      expect(parsed?.tags, [
        LspDiagnosticTag.unnecessary,
        LspDiagnosticTag.deprecated,
      ]);
    });
  });
}
