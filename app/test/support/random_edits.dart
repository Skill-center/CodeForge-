/// Random texts and CodeMirror-style change sets for the hot-exit journal's
/// property tests (test/core/journal_test.dart,
/// test/services/drift_session_store_test.dart).
library;

import 'dart:math';

const List<String> _bmp = [
  'a',
  'b',
  'Z',
  ' ',
  '\n',
  '\t',
  '{',
  '}',
  '"',
  "'",
  'é',
  '中',
];

/// Up to [maxLength] UTF-16 code units of code-like text. With [astral],
/// emoji too — whose surrogate pairs a random edit may split: fine in
/// memory, but not text a real editor produces or SQLite can store.
String randomText(Random random, int maxLength, {bool astral = true}) {
  final alphabet = astral ? [..._bmp, '😀'] : _bmp;
  final buffer = StringBuffer();
  final length = random.nextInt(maxLength + 1);
  while (buffer.length < length) {
    buffer.write(alphabet[random.nextInt(alphabet.length)]);
  }
  return buffer.toString();
}

/// A random change set over [text] in CodeMirror's JSON form — kept runs
/// and replacements (deleted length, then the inserted lines) covering the
/// whole text — as one editor transaction reports it.
List<Object?> randomChanges(Random random, String text, {bool astral = true}) {
  final positions = [
    for (var i = 0, n = 1 + random.nextInt(3); i < n; i++)
      random.nextInt(text.length + 1),
  ]..sort();
  final parts = <Object?>[];
  var pos = 0;
  for (final at in positions) {
    if (at < pos) {
      continue;
    }
    if (at > pos) {
      parts.add(at - pos);
      pos = at;
    }
    final deleted = min(random.nextInt(6), text.length - pos);
    final inserted = randomText(random, 8, astral: astral);
    if (deleted == 0 && inserted.isEmpty) {
      continue;
    }
    parts.add(
      inserted.isEmpty ? [deleted] : [deleted, ...inserted.split('\n')],
    );
    pos += deleted;
  }
  if (pos < text.length) {
    parts.add(text.length - pos);
  }
  return parts;
}
