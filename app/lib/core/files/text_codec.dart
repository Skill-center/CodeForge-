/// Text files on disk versus text in the editor
/// (docs/EDITOR_ARCHITECTURE.md, "Files").
///
/// The editor only ever holds "\n" line breaks (a protocol rule), so a
/// file's line-ending style and byte-order mark are taken off when it is
/// read and put back when it is written: a CRLF file saves as CRLF and a
/// BOM stays. Anything that is not UTF-8 text is refused, never repaired:
/// binary data (a NUL byte), malformed UTF-8 and UTF-16 or UTF-32 files.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../errors/failure.dart';

/// The UTF-8 byte-order mark.
const List<int> utf8Bom = [0xEF, 0xBB, 0xBF];

/// The largest file the editor opens: the large-file policy's hard cap
/// (core/editor/large_files.dart), checked before anything is read. 10 MiB
/// is the largest size the phase gate measured end to end.
const int maxTextFileBytes = 10 * 1024 * 1024;

/// How a file breaks its lines on disk.
enum LineEnding {
  lf('\n', 'LF'),
  crlf('\r\n', 'CRLF');

  const LineEnding(this.sequence, this.label);

  /// The characters written for one line break.
  final String sequence;

  /// The status-bar name.
  final String label;
}

/// The on-disk form of a text file: everything that is not its text.
final class TextFormat {
  const TextFormat({this.lineEnding = LineEnding.lf, this.bom = false});

  /// LF without a byte-order mark: new files.
  static const TextFormat standard = TextFormat();

  final LineEnding lineEnding;

  /// Whether the file starts with a UTF-8 byte-order mark.
  final bool bom;

  @override
  bool operator ==(Object other) =>
      other is TextFormat && other.lineEnding == lineEnding && other.bom == bom;

  @override
  int get hashCode => Object.hash(lineEnding, bom);

  @override
  String toString() => 'TextFormat(${lineEnding.label}${bom ? ', BOM' : ''})';
}

/// A decoded file: editor text plus the format to write it back with.
final class DecodedText {
  const DecodedText({
    required this.text,
    required this.format,
    this.mixedLineEndings = false,
  });

  /// The content with "\n" line breaks only, without a byte-order mark.
  final String text;

  final TextFormat format;

  /// The file mixed line-ending styles or used lone "\r" breaks. Saving
  /// writes every break as [TextFormat.lineEnding].
  final bool mixedLineEndings;
}

/// Decodes a file's [bytes] as UTF-8 text, or refuses them.
///
/// The line-ending style is CRLF when more than half of the breaks contain
/// a carriage return (the rule VS Code uses), otherwise LF.
Result<DecodedText> decodeText(Uint8List bytes) {
  if (_startsWith(bytes, const [0xFF, 0xFE]) ||
      _startsWith(bytes, const [0xFE, 0xFF])) {
    return const Err(
      FileFailure(
        'This is a UTF-16 or UTF-32 file. CodeForge edits UTF-8 text only.',
        problem: FileProblem.notText,
      ),
    );
  }
  final bom = _startsWith(bytes, utf8Bom);
  final start = bom ? utf8Bom.length : 0;
  if (bytes.indexOf(0, start) >= 0) {
    return const Err(
      FileFailure(
        'This looks like a binary file, so it was not opened as text.',
        problem: FileProblem.notText,
      ),
    );
  }
  final String raw;
  try {
    raw = const Utf8Decoder().convert(bytes, start);
  } on FormatException catch (error) {
    return Err(
      FileFailure(
        'This file is not valid UTF-8 text, so it was not opened.',
        problem: FileProblem.notText,
        cause: error,
      ),
    );
  }
  var lf = 0;
  var crlf = 0;
  var cr = 0;
  var i = 0;
  while (i < raw.length) {
    final unit = raw.codeUnitAt(i);
    if (unit == 0x0A) {
      lf++;
    } else if (unit == 0x0D) {
      if (i + 1 < raw.length && raw.codeUnitAt(i + 1) == 0x0A) {
        crlf++;
        i++;
      } else {
        cr++;
      }
    }
    i++;
  }
  final breaks = lf + crlf + cr;
  final lineEnding = breaks > 0 && (crlf + cr) * 2 > breaks
      ? LineEnding.crlf
      : LineEnding.lf;
  final styles = (lf > 0 ? 1 : 0) + (crlf > 0 ? 1 : 0) + (cr > 0 ? 1 : 0);
  return Ok(
    DecodedText(
      text: crlf + cr == 0 ? raw : normalizeLineBreaks(raw),
      format: TextFormat(lineEnding: lineEnding, bom: bom),
      mixedLineEndings: styles > 1 || cr > 0,
    ),
  );
}

/// Encodes editor [text] for disk in [format]. Any carriage return left in
/// [text] is normalised first, so the result never mixes styles.
Uint8List encodeText(String text, TextFormat format) {
  final lines = text.contains('\r') ? normalizeLineBreaks(text) : text;
  final onDisk = format.lineEnding == LineEnding.crlf
      ? lines.replaceAll('\n', '\r\n')
      : lines;
  final encoded = utf8.encode(onDisk);
  if (!format.bom) {
    return encoded;
  }
  return Uint8List(encoded.length + utf8Bom.length)
    ..setRange(0, utf8Bom.length, utf8Bom)
    ..setRange(utf8Bom.length, utf8Bom.length + encoded.length, encoded);
}

/// [text] with every "\r\n" and lone "\r" turned into "\n".
String normalizeLineBreaks(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// The first line of [text], at most [limit] characters (shebang sniffing).
String firstLineOf(String text, {int limit = 256}) {
  final end = text.indexOf('\n');
  final line = end < 0 ? text : text.substring(0, end);
  return line.length > limit ? line.substring(0, limit) : line;
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}
