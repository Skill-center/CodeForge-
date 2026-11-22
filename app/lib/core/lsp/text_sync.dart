/// The editor's change sets as LSP's incremental changes (Phase 6 W4).
///
/// The page sends Dart each batch of edits (about 150 ms of typing) as one
/// CodeMirror change set, with offsets into the text before the batch
/// (core/editor/change_set.dart). LSP wants ranges, in lines and UTF-16
/// characters, applied one after another, each to the text the ones before
/// it left. So every replaced span becomes one range, computed against the
/// text before the batch, and the ranges go last first: each one lies before
/// every span already replaced, where nothing has moved.
///
/// Lines end at `\n`, `\r\n` or a lone `\r`, as LSP counts them, and
/// characters are UTF-16 code units, so a surrogate pair counts two. An
/// offset between a `\r` and its `\n` has no LSP position; the editor's own
/// text never has one, since it only ever holds `\n` (a CRLF file is shown
/// with `\n` and saved with CRLF), so the servers see what the editor shows.
library;

import '../editor/change_set.dart';
import 'lsp_models.dart';

/// Where each line of a text starts, for turning UTF-16 offsets into LSP's
/// positions and back.
final class LineIndex {
  LineIndex(this.text) : _starts = _lineStarts(text);

  final String text;
  final List<int> _starts;

  int get lineCount => _starts.length;

  /// The position of [offset], a UTF-16 offset clamped into the text.
  LspPosition positionAt(int offset) {
    final at = offset.clamp(0, text.length);
    var low = 0;
    var high = _starts.length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (_starts[middle] <= at) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return LspPosition(low, at - _starts[low]);
  }

  /// The UTF-16 offset of [position]. A line past the end means the text's
  /// end, and a character past its line's end that line's end (LSP's rule).
  int offsetAt(LspPosition position) {
    if (position.line >= _starts.length) {
      return text.length;
    }
    final start = _starts[position.line];
    final end = position.line + 1 < _starts.length
        ? _contentEnd(_starts[position.line + 1])
        : text.length;
    return (start + position.character).clamp(start, end);
  }

  /// Where the line that ends just before [nextStart] ends, its break left
  /// out.
  int _contentEnd(int nextStart) {
    var end = nextStart;
    if (end > 0 && text.codeUnitAt(end - 1) == 0x0A) {
      end -= 1;
      if (end > 0 && text.codeUnitAt(end - 1) == 0x0D) {
        end -= 1;
      }
    } else if (end > 0 && text.codeUnitAt(end - 1) == 0x0D) {
      end -= 1;
    }
    return end;
  }
}

List<int> _lineStarts(String text) {
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x0A) {
      starts.add(i + 1);
    } else if (unit == 0x0D) {
      if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) {
        i += 1;
      }
      starts.add(i + 1);
    }
  }
  return starts;
}

/// [changes] (CodeMirror change-set JSON, offsets into [before]) as LSP's
/// `contentChanges`: one range and its new text per replaced span, the last
/// span first. Throws [ChangeApplyException] for a change set that does not
/// cover [before] exactly, as `applyChanges` does.
List<Map<String, Object?>> contentChangesFor(
  String before,
  List<Object?> changes,
) {
  final index = LineIndex(before);
  final ranges = <Map<String, Object?>>[];
  var position = 0;
  for (final part in changes) {
    if (part is num) {
      final keep = part.toInt();
      if (keep < 0 || position + keep > before.length) {
        throw const ChangeApplyException(
          'change set is longer than the document',
        );
      }
      position += keep;
      continue;
    }
    if (part is! List<Object?> || part.isEmpty) {
      throw const ChangeApplyException('malformed change set');
    }
    final head = part.first;
    if (head is! num || head < 0) {
      throw const ChangeApplyException('malformed change set');
    }
    final deleted = head.toInt();
    if (position + deleted > before.length) {
      throw const ChangeApplyException(
        'change set is longer than the document',
      );
    }
    final lines = <String>[];
    for (var i = 1; i < part.length; i++) {
      final line = part[i];
      if (line is! String) {
        throw const ChangeApplyException('malformed change set');
      }
      lines.add(line);
    }
    final inserted = lines.join('\n');
    if (deleted > 0 || inserted.isNotEmpty) {
      ranges.add({
        'range': LspRange(
          index.positionAt(position),
          index.positionAt(position + deleted),
        ).toJson(),
        'text': inserted,
      });
    }
    position += deleted;
  }
  if (position != before.length) {
    throw const ChangeApplyException('change set is shorter than the document');
  }
  return ranges.reversed.toList();
}

/// [text] with LSP's [contentChanges] applied in order, as a server applies
/// them: what the tests hold the conversion to. A change without a range
/// replaces the whole text.
String applyContentChanges(String text, List<Map<String, Object?>> changes) {
  var current = text;
  for (final change in changes) {
    final replacement = change['text'];
    if (replacement is! String) {
      throw const ChangeApplyException('a content change without text');
    }
    final range = LspRange.fromJson(change['range']);
    if (range == null) {
      current = replacement;
      continue;
    }
    final index = LineIndex(current);
    final start = index.offsetAt(range.start);
    final end = index.offsetAt(range.end);
    if (end < start) {
      throw const ChangeApplyException(
        'a content change ends before it starts',
      );
    }
    current = current.replaceRange(start, end, replacement);
  }
  return current;
}
