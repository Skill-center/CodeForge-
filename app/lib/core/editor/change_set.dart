/// Applies CodeMirror change-set JSON to plain text: the Dart mirror of
/// editor/src/protocol/changes.ts, held to the same fixtures
/// (editor/test/fixtures/changes/, run by test/core/editor_protocol_test.dart).
///
/// Change-set JSON: a number keeps that many characters, `[n]` deletes n
/// characters, and `[n, ...lines]` replaces n characters with the lines
/// joined by "\n". Positions are UTF-16 code units, as in Dart strings.
library;

/// A change set that does not fit the text it was applied to.
final class ChangeApplyException implements Exception {
  const ChangeApplyException(this.message);

  final String message;

  @override
  String toString() => 'ChangeApplyException: $message';
}

/// Document lengths (UTF-16 code units) before and after [changes].
({int before, int after}) changeLengths(List<Object?> changes) {
  var before = 0;
  var after = 0;
  for (final part in changes) {
    if (part is num) {
      before += part.toInt();
      after += part.toInt();
      continue;
    }
    final (deleted, lines) = _replacement(part);
    before += deleted;
    if (lines.isNotEmpty) {
      after += lines.length - 1;
      for (final line in lines) {
        after += line.length;
      }
    }
  }
  return (before: before, after: after);
}

/// Returns [text] with [changes] applied.
///
/// Throws [ChangeApplyException] when the change set does not cover [text]
/// exactly, so a stale or corrupted change can never be half-applied.
String applyChanges(String text, List<Object?> changes) {
  final out = StringBuffer();
  var pos = 0;
  for (final part in changes) {
    if (part is num) {
      final keep = part.toInt();
      if (keep < 0 || pos + keep > text.length) {
        throw const ChangeApplyException(
          'change set is longer than the document',
        );
      }
      out.write(text.substring(pos, pos + keep));
      pos += keep;
      continue;
    }
    final (deleted, lines) = _replacement(part);
    if (pos + deleted > text.length) {
      throw const ChangeApplyException(
        'change set is longer than the document',
      );
    }
    pos += deleted;
    if (lines.isNotEmpty) {
      out.write(lines.join('\n'));
    }
  }
  if (pos != text.length) {
    throw const ChangeApplyException('change set is shorter than the document');
  }
  return out.toString();
}

/// Splits a `[deleted, ...lines]` part, rejecting anything malformed.
(int, List<String>) _replacement(Object? part) {
  if (part is! List<Object?> || part.isEmpty) {
    throw const ChangeApplyException('malformed change set');
  }
  final deleted = part.first;
  if (deleted is! num || deleted < 0) {
    throw const ChangeApplyException('malformed change set');
  }
  final lines = <String>[];
  for (var i = 1; i < part.length; i++) {
    final line = part[i];
    if (line is! String) {
      throw const ChangeApplyException('malformed change set');
    }
    lines.add(line);
  }
  return (deleted.toInt(), lines);
}
