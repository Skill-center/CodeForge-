/// The editor's change sets as LSP's incremental changes (Phase 6 W4, gate
/// G4): positions in UTF-16 with surrogate pairs and CRLF, the ranges of a
/// change set last first, and every one applied in order giving the text
/// the change set gives, over fixed cases and a seeded fuzz.
library;

import 'dart:math';

import 'package:codeforge/core/editor/change_set.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/core/lsp/text_sync.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _range(int l1, int c1, int l2, int c2) => {
  'start': {'line': l1, 'character': c1},
  'end': {'line': l2, 'character': c2},
};

void main() {
  group('positions', () {
    test('count UTF-16 code units: a surrogate pair is two', () {
      final index = LineIndex('a😀b\nc');
      expect(index.lineCount, 2);
      expect(index.positionAt(1), const LspPosition(0, 1));
      // 😀 is two code units: b starts at 3.
      expect(index.positionAt(3), const LspPosition(0, 3));
      expect(index.positionAt(5), const LspPosition(1, 0));
      expect(index.positionAt(6), const LspPosition(1, 1));
      expect(index.offsetAt(const LspPosition(0, 3)), 3);
      expect(index.offsetAt(const LspPosition(1, 1)), 6);
    });

    test(r'a line ends at \n, \r\n or a lone \r, as LSP counts lines', () {
      const text = 'one\r\ntwo\rthree\nfour';
      final index = LineIndex(text);
      expect(index.lineCount, 4);
      expect(index.positionAt(text.indexOf('two')), const LspPosition(1, 0));
      expect(index.positionAt(text.indexOf('three')), const LspPosition(2, 0));
      expect(index.positionAt(text.indexOf('four')), const LspPosition(3, 0));
      expect(index.positionAt(text.length), const LspPosition(3, 4));
      // A character past its line's end is that line's end, its break left
      // out; a line past the end is the text's end.
      expect(index.offsetAt(const LspPosition(0, 99)), 3);
      expect(index.offsetAt(const LspPosition(1, 99)), text.indexOf('\rthree'));
      expect(index.offsetAt(const LspPosition(9, 0)), text.length);
    });

    test('offsets outside the text are clamped', () {
      final index = LineIndex('ab');
      expect(index.positionAt(-4), const LspPosition(0, 0));
      expect(index.positionAt(99), const LspPosition(0, 2));
    });
  });

  group('change sets to ranges', () {
    test('an insertion is an empty range with its text', () {
      expect(contentChangesFor('hello\nworld', [6, [0, 'big '], 5]), [
        {'range': _range(1, 0, 1, 0), 'text': 'big '},
      ]);
    });

    test('a deletion across lines is a range with no text', () {
      expect(contentChangesFor('ab\ncd\nef', [1, [5], 2]), [
        {'range': _range(0, 1, 2, 0), 'text': ''},
      ]);
    });

    test('lines replaced join with \\n', () {
      expect(
        contentChangesFor('x = 1', [
          4,
          [1, '[', '  1,', ']'],
        ]),
        [
          {'range': _range(0, 4, 0, 5), 'text': '[\n  1,\n]'},
        ],
      );
    });

    test('several spans go last first, each as the text before had it', () {
      const before = 'alpha\nbeta\ngamma\n';
      final changes = <Object?>[
        [1, 'A'],
        5,
        [4, 'BETA'],
        1,
        [0, '>> '],
        6,
      ];
      final ranges = contentChangesFor(before, changes);
      expect(ranges, [
        {'range': _range(2, 0, 2, 0), 'text': '>> '},
        {'range': _range(1, 0, 1, 4), 'text': 'BETA'},
        {'range': _range(0, 0, 0, 1), 'text': 'A'},
      ]);
      expect(
        applyContentChanges(before, ranges),
        applyChanges(before, changes),
      );
      expect(applyContentChanges(before, ranges), 'Alpha\nBETA\n>> gamma\n');
    });

    test('positions after an emoji count it as two', () {
      const before = '😀😀 x\n';
      final ranges = contentChangesFor(before, [
        5,
        [1, 'y'],
        1,
      ]);
      expect(ranges, [
        {'range': _range(0, 5, 0, 6), 'text': 'y'},
      ]);
      expect(applyContentChanges(before, ranges), '😀😀 y\n');
    });

    test(r'a CRLF text keeps its lines: \r\n counts once', () {
      const before = 'one\r\ntwo\r\nthree';
      final changes = <Object?>[
        5,
        [3, '2'],
        2,
        [0, '3: '],
        5,
      ];
      final ranges = contentChangesFor(before, changes);
      expect(ranges, [
        {'range': _range(2, 0, 2, 0), 'text': '3: '},
        {'range': _range(1, 0, 1, 3), 'text': '2'},
      ]);
      expect(
        applyContentChanges(before, ranges),
        applyChanges(before, changes),
      );
    });

    test('a change set that does not fit the text is refused', () {
      expect(
        () => contentChangesFor('abc', [4]),
        throwsA(isA<ChangeApplyException>()),
      );
      expect(
        () => contentChangesFor('abc', [2]),
        throwsA(isA<ChangeApplyException>()),
      );
      expect(
        () => contentChangesFor('abc', [
          ['x'],
        ]),
        throwsA(isA<ChangeApplyException>()),
      );
      expect(
        () => contentChangesFor('abc', [
          [1, 7],
          2,
        ]),
        throwsA(isA<ChangeApplyException>()),
      );
    });

    test('a change set that changes nothing sends nothing', () {
      expect(contentChangesFor('abc', [3]), isEmpty);
      expect(contentChangesFor('', <Object?>[]), isEmpty);
    });

    test('applied in order, the ranges give what the change set gives '
        '(seeded fuzz)', () {
      final random = Random(7);
      const pieces = ['a', 'b', '\n', '😀', 'é', ' ', 'xyz'];
      String some(int most) => [
        for (var i = random.nextInt(most + 1); i > 0; i--)
          pieces[random.nextInt(pieces.length)],
      ].join();
      for (var trial = 0; trial < 2000; trial++) {
        final before = some(24);
        final changes = <Object?>[];
        var at = 0;
        while (at < before.length) {
          final keep = random.nextInt(before.length - at + 1);
          if (keep > 0) {
            changes.add(keep);
            at += keep;
          }
          if (at >= before.length) {
            break;
          }
          if (random.nextBool()) {
            final deleted = random.nextInt(before.length - at + 1);
            changes.add([
              deleted,
              for (var line = random.nextInt(3); line > 0; line--) some(3),
            ]);
            at += deleted;
          }
        }
        if (random.nextInt(4) == 0) {
          changes.add([0, some(4)]);
        }
        final ranges = contentChangesFor(before, changes);
        expect(
          applyContentChanges(before, ranges),
          applyChanges(before, changes),
          reason: 'trial $trial: $before / $changes',
        );
      }
    });
  });
}
