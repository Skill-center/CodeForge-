/// The text codec (Phase 2 W4, gate G2): what a file's bytes become in the
/// editor and back. Byte-order marks and CRLF survive a round trip; binary
/// and malformed files are refused, never repaired.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

DecodedText _decode(List<int> bytes) => decodeText(_bytes(bytes)).orThrow;

FileProblem? _refusal(List<int> bytes) {
  final failure = decodeText(_bytes(bytes)).failureOrNull;
  return failure is FileFailure ? failure.problem : null;
}

void main() {
  group('decode', () {
    test('plain LF text without a BOM', () {
      final decoded = _decode(utf8.encode('a\nb\n'));
      expect(decoded.text, 'a\nb\n');
      expect(decoded.format, TextFormat.standard);
      expect(decoded.mixedLineEndings, isFalse);
    });

    test('CRLF becomes \\n in the editor and is remembered', () {
      final decoded = _decode(utf8.encode('a\r\nb\r\n'));
      expect(decoded.text, 'a\nb\n');
      expect(decoded.format.lineEnding, LineEnding.crlf);
      expect(decoded.mixedLineEndings, isFalse);
    });

    test('the BOM is taken off the text and remembered', () {
      final decoded = _decode([...utf8Bom, ...utf8.encode('é\r\n')]);
      expect(decoded.text, 'é\n');
      expect(
        decoded.format,
        const TextFormat(lineEnding: LineEnding.crlf, bom: true),
      );
    });

    test('mixed endings: the majority wins and the file is flagged', () {
      final mostlyCrlf = _decode(utf8.encode('a\r\nb\r\nc\n'));
      expect(mostlyCrlf.format.lineEnding, LineEnding.crlf);
      expect(mostlyCrlf.mixedLineEndings, isTrue);
      expect(mostlyCrlf.text, 'a\nb\nc\n');

      // A tie stays LF.
      final tie = _decode(utf8.encode('a\r\nb\n'));
      expect(tie.format.lineEnding, LineEnding.lf);
      expect(tie.mixedLineEndings, isTrue);
    });

    test('lone CR breaks are normalised and flagged', () {
      final decoded = _decode(utf8.encode('a\rb\r'));
      expect(decoded.text, 'a\nb\n');
      expect(decoded.format.lineEnding, LineEnding.crlf);
      expect(decoded.mixedLineEndings, isTrue);
    });

    test('an empty file is empty LF text', () {
      final decoded = _decode(const []);
      expect(decoded.text, '');
      expect(decoded.format, TextFormat.standard);
    });

    test('binary, malformed and UTF-16 files are refused', () {
      expect(
        _refusal([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D]),
        FileProblem.notText,
      );
      expect(_refusal(utf8.encode('text\u0000more')), FileProblem.notText);
      // Latin-1 "café".
      expect(_refusal([0x63, 0x61, 0x66, 0xE9]), FileProblem.notText);
      // A truncated multi-byte sequence.
      expect(_refusal([0x61, 0xE2, 0x82]), FileProblem.notText);
      // UTF-16 LE and BE byte-order marks.
      expect(_refusal([0xFF, 0xFE, 0x61, 0x00]), FileProblem.notText);
      expect(_refusal([0xFE, 0xFF, 0x00, 0x61]), FileProblem.notText);
    });
  });

  group('encode', () {
    test('writes the remembered style and BOM', () {
      expect(
        encodeText('a\nb\n', const TextFormat(lineEnding: LineEnding.crlf)),
        utf8.encode('a\r\nb\r\n'),
      );
      expect(encodeText('x', const TextFormat(bom: true)), [...utf8Bom, 0x78]);
    });

    test('never writes a stray carriage return', () {
      expect(
        encodeText('a\r\nb\rc', TextFormat.standard),
        utf8.encode('a\nb\nc'),
      );
      expect(
        encodeText('a\r\nb', const TextFormat(lineEnding: LineEnding.crlf)),
        utf8.encode('a\r\nb'),
      );
    });
  });

  group('round trip', () {
    for (final (name, bytes) in [
      ('LF', utf8.encode('const a = 1;\nconst b = 2;\n')),
      ('CRLF', utf8.encode('line one\r\nline two\r\n')),
      ('BOM + CRLF', [...utf8Bom, ...utf8.encode('x\r\ny\r\n')]),
      ('BOM + LF', [...utf8Bom, ...utf8.encode('x\ny')]),
      ('no final newline', utf8.encode('end')),
      ('emoji and accents', utf8.encode('héllo 👋\r\nwörld\r\n')),
      ('empty', <int>[]),
    ]) {
      test('$name: unchanged text saves the same bytes', () {
        final decoded = _decode(bytes);
        expect(encodeText(decoded.text, decoded.format), bytes);
      });
    }

    test('editor text survives encode then decode in any format', () {
      const text = 'a\n\nb ✓\n';
      for (final format in const [
        TextFormat.standard,
        TextFormat(lineEnding: LineEnding.crlf),
        TextFormat(bom: true),
        TextFormat(lineEnding: LineEnding.crlf, bom: true),
      ]) {
        final decoded = decodeText(encodeText(text, format)).orThrow;
        expect(decoded.text, text);
        expect(decoded.format, format);
      }
    });
  });

  test('firstLineOf stops at the first break and at the limit', () {
    expect(firstLineOf('#!/usr/bin/env node\nrest'), '#!/usr/bin/env node');
    expect(firstLineOf('single'), 'single');
    expect(firstLineOf('x' * 300).length, 256);
  });
}
