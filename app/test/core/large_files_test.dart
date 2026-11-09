/// The large-file policy (Phase 2 W7, core/editor/large_files.dart): which
/// documents open as plain text, the hard cap's place, and how sizes read
/// in messages.
library;

import 'package:codeforge/core/editor/languages.dart';
import 'package:codeforge/core/editor/large_files.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('plain text', () {
    test('a highlighted language turns plain only above the threshold', () {
      expect(opensAsPlainText(0, 'python'), isFalse);
      expect(opensAsPlainText(plainTextAboveChars, 'javascript'), isFalse);
      expect(opensAsPlainText(plainTextAboveChars + 1, 'javascript'), isTrue);
      expect(opensAsPlainText(maxTextFileBytes, 'markdown'), isTrue);
    });

    test('plain text has nothing to switch off', () {
      expect(languageForPath('notes.txt'), plainTextLanguage);
      expect(
        opensAsPlainText(plainTextAboveChars * 4, plainTextLanguage),
        isFalse,
      );
    });

    test('the threshold is below the measured 1 MiB and the hard cap', () {
      // ADR-0004: a highlighted 1 MiB document was over the typing budget
      // on a phone, so the policy has to make it plain text.
      expect(plainTextAboveChars, lessThan(1024 * 1024));
      expect(plainTextAboveChars, lessThan(maxTextFileBytes));
    });
  });

  group('formatMegabytes', () {
    test('whole megabytes have no decimal', () {
      expect(formatMegabytes(0), '0 MB');
      expect(formatMegabytes(10 * 1024 * 1024), '10 MB');
    });

    test('a size over a limit never reads as the limit', () {
      expect(formatMegabytes(10 * 1024 * 1024 + 1), '10.1 MB');
      expect(formatMegabytes(12 * 1024 * 1024 + 300 * 1024), '12.3 MB');
      expect(formatMegabytes(1), '0.1 MB');
    });
  });
}
