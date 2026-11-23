/// A rename's edits (Phase 6 W5, core/lsp/workspace_edit.dart): the
/// WorkspaceEdit read in both its forms, file operations refused, and each
/// file's edits applied exactly or not at all.
library;

import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/core/lsp/workspace_edit.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _edit(int sl, int sc, int el, int ec, String text) => {
  'range': {
    'start': {'line': sl, 'character': sc},
    'end': {'line': el, 'character': ec},
  },
  'newText': text,
};

LspTextEdit _e(int sl, int sc, int el, int ec, String text) =>
    LspTextEdit(LspRange(LspPosition(sl, sc), LspPosition(el, ec)), text);

void main() {
  group('reading a WorkspaceEdit', () {
    test('changes: by URI', () {
      final parsed = parseWorkspaceEdit({
        'changes': {
          'file:///w/a.py': [_edit(0, 4, 0, 9, 'welcome')],
          'file:///w/b.py': [_edit(2, 0, 2, 5, 'welcome')],
          'file:///w/c.py': <Object?>[],
        },
      });
      expect(parsed.problem, isNull);
      expect(
        [for (final f in parsed.files) f.uri],
        ['file:///w/a.py', 'file:///w/b.py'],
      );
      expect(parsed.files.first.version, isNull);
    });

    test("documentChanges: each document's version", () {
      final parsed = parseWorkspaceEdit({
        'documentChanges': [
          {
            'textDocument': {'uri': 'file:///w/a.ts', 'version': 7},
            'edits': [_edit(0, 0, 0, 5, 'hello')],
          },
          {
            'textDocument': {'uri': 'file:///w/b.ts', 'version': null},
            'edits': [_edit(1, 0, 1, 5, 'hello')],
          },
        ],
      });
      expect(parsed.problem, isNull);
      expect(parsed.files.first.version, 7);
      expect(parsed.files.last.version, isNull);
    });

    test('creating, renaming or deleting files is refused', () {
      final parsed = parseWorkspaceEdit({
        'documentChanges': [
          {
            'kind': 'rename',
            'oldUri': 'file:///w/a.py',
            'newUri': 'file:///w/b.py',
          },
        ],
      });
      expect(parsed.files, isEmpty);
      expect(parsed.problem, contains('rename or delete files'));
    });

    test('malformed edits are refused', () {
      for (final edit in [
        null,
        {'changes': 3},
        {
          'changes': {
            'file:///w/a.py': [
              {'newText': 'x'},
            ],
          },
        },
        {
          'documentChanges': [
            {'edits': <Object?>[]},
          ],
        },
        {
          'documentChanges': [
            {
              'textDocument': {'uri': 'file:///w/a.py', 'version': 1},
              'edits': [_edit(0, 0, 0, 1, 'x')],
            },
            {
              'textDocument': {'uri': 'file:///w/a.py', 'version': 2},
              'edits': [_edit(1, 0, 1, 1, 'y')],
            },
          ],
        },
      ]) {
        expect(parseWorkspaceEdit(edit).problem, isNotNull, reason: '$edit');
      }
    });
  });

  group('applying edits', () {
    const text = 'def greet():\n    pass\ngreet()\n';

    test('in any order, as offsets, the old name checked', () {
      final applied = applyTextEdits(text, [
        _e(2, 0, 2, 5, 'welcome'),
        _e(0, 4, 0, 9, 'welcome'),
      ], expected: 'greet');
      expect(applied.problem, isNull);
      expect(applied.text, 'def welcome():\n    pass\nwelcome()\n');
      expect(applied.offsets, [
        (from: 4, to: 9, insert: 'welcome'),
        (from: 22, to: 27, insert: 'welcome'),
      ]);
    });

    test('a span that is not the old name: the file changed', () {
      expect(
        applyTextEdits(text, [_e(0, 4, 0, 9, 'x')], expected: 'greed').problem,
        EditProblem.changed,
      );
    });

    test('outside the text: past a line, or past the last line', () {
      expect(
        applyTextEdits(text, [_e(0, 4, 0, 40, 'x')]).problem,
        EditProblem.outside,
      );
      expect(
        applyTextEdits(text, [_e(9, 0, 9, 0, 'x')]).problem,
        EditProblem.outside,
      );
      expect(
        applyTextEdits(text, [_e(0, 5, 0, 4, 'x')]).problem,
        EditProblem.outside,
      );
    });

    test('overlapping edits are refused', () {
      expect(
        applyTextEdits(text, [
          _e(0, 0, 0, 5, 'x'),
          _e(0, 3, 0, 6, 'y'),
        ]).problem,
        EditProblem.overlapping,
      );
    });

    test('insertions at one place keep their order', () {
      final applied = applyTextEdits('ab', [
        _e(0, 1, 0, 1, 'X'),
        _e(0, 1, 0, 1, 'Y'),
        _e(0, 0, 0, 1, 'Z'),
      ]);
      expect(applied.text, 'ZXYb');
    });

    test('a file with CRLF line breaks: a line ends before its CR', () {
      const crlf = 'a = 1\r\nb = a\r\n';
      final applied = applyTextEdits(crlf, [
        _e(1, 4, 1, 5, 'c'),
        _e(0, 0, 0, 1, 'c'),
      ], expected: 'a');
      expect(applied.text, 'c = 1\r\nb = c\r\n');
      expect(
        applyTextEdits(crlf, [_e(0, 6, 0, 6, 'x')]).problem,
        EditProblem.outside,
      );
    });

    test("the new text's line breaks become \\n", () {
      expect(applyTextEdits('x', [_e(0, 1, 0, 1, '\r\ny\r')]).text, 'x\ny\n');
    });
  });
}
