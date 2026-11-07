/// Go to line (Phase 2 W6): what the user types, read as a place.
library;

import 'package:codeforge/core/editor/line_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLineTarget', () {
    LineTarget? target(String input, {int lineCount = 100}) =>
        parseLineTarget(input, lineCount: lineCount).target;
    String? problem(String input, {int lineCount = 100}) =>
        parseLineTarget(input, lineCount: lineCount).problem;

    test('reads a line, and a column after any separator', () {
      expect(target('42'), const LineTarget(42));
      expect(target(' 42 '), const LineTarget(42));
      expect(target('42:7'), const LineTarget(42, 7));
      expect(target('42, 7'), const LineTarget(42, 7));
      expect(target('42.7'), const LineTarget(42, 7));
    });

    test('takes a line past the end as the last line', () {
      expect(target('500', lineCount: 12), const LineTarget(12));
      expect(target('500:3', lineCount: 12), const LineTarget(12, 3));
      expect(target('1', lineCount: 0), const LineTarget(1));
    });

    test('says what is wrong with anything else', () {
      expect(problem(''), 'Type a line number.');
      expect(problem('   '), 'Type a line number.');
      expect(problem('0'), 'Lines start at 1.');
      expect(problem('3:0'), 'Columns start at 1.');
      for (final input in ['abc', '-3', '4:', ':4', '1:2:3', '12345678901']) {
        expect(problem(input), 'Type a line number, like 42 or 42:7.');
        expect(target(input), isNull);
      }
    });
  });

  test('lineCountOf counts the line after the last break', () {
    expect(lineCountOf(''), 1);
    expect(lineCountOf('a'), 1);
    expect(lineCountOf('a\nb'), 2);
    expect(lineCountOf('a\n'), 2);
  });

  test('lineAtOffset finds the line holding an offset, clamped', () {
    const text = 'ab\ncd\nef';
    expect(lineAtOffset(text, 0), 1);
    expect(lineAtOffset(text, 2), 1);
    expect(lineAtOffset(text, 3), 2);
    expect(lineAtOffset(text, 8), 3);
    expect(lineAtOffset(text, 99), 3);
    expect(lineAtOffset(text, -4), 1);
  });
}
