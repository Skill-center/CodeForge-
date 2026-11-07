/// What the user types into "Go to line" (Phase 2 W6): a line number,
/// optionally followed by a column, as `42`, `42:7`, `42,7` or `42.7` (a
/// phone's number pad may offer only `.` or `,`).
library;

/// A 1-based line, and optionally a 1-based column, to move the cursor to.
final class LineTarget {
  const LineTarget(this.line, [this.column]);

  final int line;
  final int? column;

  @override
  bool operator ==(Object other) =>
      other is LineTarget && other.line == line && other.column == column;

  @override
  int get hashCode => Object.hash(line, column);

  @override
  String toString() =>
      column == null ? 'LineTarget($line)' : 'LineTarget($line:$column)';
}

final RegExp _pattern = RegExp(r'^(\d{1,9})(?:\s*[:,.]\s*(\d{1,9}))?$');

/// Reads [input] as a place in a document of [lineCount] lines. A line past
/// the end means the last line, as the editor treats it; anything else that
/// is not a place comes back as a [problem] fit to show under the field.
({LineTarget? target, String? problem}) parseLineTarget(
  String input, {
  required int lineCount,
}) {
  final text = input.trim();
  if (text.isEmpty) {
    return (target: null, problem: 'Type a line number.');
  }
  final match = _pattern.firstMatch(text);
  if (match == null) {
    return (target: null, problem: 'Type a line number, like 42 or 42:7.');
  }
  final line = int.parse(match.group(1)!);
  final columnText = match.group(2);
  final column = columnText == null ? null : int.parse(columnText);
  if (line < 1) {
    return (target: null, problem: 'Lines start at 1.');
  }
  if (column != null && column < 1) {
    return (target: null, problem: 'Columns start at 1.');
  }
  final last = lineCount < 1 ? 1 : lineCount;
  return (target: LineTarget(line > last ? last : line, column), problem: null);
}

/// The number of lines in [text]: one more than its line breaks.
int lineCountOf(String text) => '\n'.allMatches(text).length + 1;

/// The 1-based line holding [offset] in [text].
int lineAtOffset(String text, int offset) {
  var end = offset;
  if (end < 0) {
    end = 0;
  } else if (end > text.length) {
    end = text.length;
  }
  return '\n'.allMatches(text.substring(0, end)).length + 1;
}
