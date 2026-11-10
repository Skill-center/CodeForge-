/// The large-file gate's files and the Developer action's (Phase 3 W1, gate
/// G6): the same seven files, byte for byte. The digests were computed with
/// Node from editor/bench/samples.ts, the generator's original
/// (editor/test/bench.test.ts pins the same ones), so the Dart port, the
/// gate and the Developer action all write what the TypeScript benchmark
/// generates.
library;

import 'dart:convert';

import 'package:codeforge/core/editor/large_files.dart';
import 'package:codeforge/core/editor/large_samples.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// name → (target chars, generated chars, SHA-256 of the UTF-8 bytes).
const Map<String, (int, int, String)> _pins = {
  'large_512kb.js': (
    524160,
    524164,
    'afc78e8f04e8ce74613755f4459287c4c10223d0feb003fe8bda3ebd711c357e',
  ),
  'large_1mb.js': (
    1048576,
    1048614,
    'bdc70485be76830f76676be3fa652f55f68cbd906f502f3dddfd6c7d31928055',
  ),
  'large_1mb.txt': (
    1048576,
    1048614,
    'bdc70485be76830f76676be3fa652f55f68cbd906f502f3dddfd6c7d31928055',
  ),
  'large_5mb.js': (
    5242880,
    5242929,
    '909e9b7c99b1d21ac5da67c9b2b440e4930341b044602c407105dd6b6068f756',
  ),
  'large_5mb.txt': (
    5242880,
    5242929,
    '909e9b7c99b1d21ac5da67c9b2b440e4930341b044602c407105dd6b6068f756',
  ),
  'large_10mb.js': (
    10485632,
    10485681,
    'c21701a8065528b5562ea35f2d86f1661bf7e605dde6351ad66c2d6ea8e51c64',
  ),
  'large_10mb.txt': (
    10485632,
    10485681,
    'c21701a8065528b5562ea35f2d86f1661bf7e605dde6351ad66c2d6ea8e51c64',
  ),
};

void main() {
  test('the seven files, smallest first, with the gate\'s sizes', () {
    expect([for (final s in largeSamples) s.name], _pins.keys.toList());
    for (final sample in largeSamples) {
      expect(sample.chars, _pins[sample.name]!.$1, reason: sample.name);
    }
    expect(largeLimitChars, plainTextAboveChars - 128);
    expect(largeSampleChars(10), maxTextFileBytes - 128);
  });

  test('each file is byte for byte what the TypeScript generator makes', () {
    final digests = <int, String>{};
    for (final sample in largeSamples) {
      final (_, length, digest) = _pins[sample.name]!;
      final actual = digests.putIfAbsent(sample.chars, () {
        final text = largeJavaScript(sample.chars);
        expect(text.length, length, reason: sample.name);
        expect(text.endsWith('\n'), isTrue);
        // ASCII: characters are bytes, and no file passes the size cap.
        final bytes = utf8.encode(text);
        expect(bytes.length, text.length);
        expect(bytes.length, lessThanOrEqualTo(maxTextFileBytes));
        return sha256.convert(bytes).toString();
      });
      expect(actual, digest, reason: sample.name);
    }
  });

  test('the files sit on either side of the plain-text threshold', () {
    final limit = largeSamples.first;
    expect(largeJavaScript(limit.chars).length, lessThan(plainTextAboveChars));
    for (final sample in largeSamples.skip(1)) {
      expect(sample.chars, greaterThan(plainTextAboveChars));
    }
  });
}
