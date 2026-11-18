/// The source offer and CodeForge's license as About shows them (Phase 5
/// W1) are the repository's own: SOURCE_OFFER.md's words, LICENSE's text.
library;

import 'dart:io';

import 'package:codeforge/core/legal/source_offer.dart';
import 'package:codeforge/core/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SOURCE_OFFER.md carries the offer About shows, word for word', () {
    final offer = File('../SOURCE_OFFER.md').readAsStringSync();
    final start = offer.indexOf('## The offer in the app');
    expect(start, isNonNegative, reason: 'SOURCE_OFFER.md has the section');
    final section = offer.substring(start);
    var from = 0;
    for (final paragraph in sourceOfferParagraphs('{version}')) {
      final at = section.indexOf('> $paragraph\n', from);
      expect(at, greaterThanOrEqualTo(from), reason: 'in order: $paragraph');
      from = at + paragraph.length;
    }
  });

  test("the offer names this version's archive and where to ask", () {
    final text = sourceOfferParagraphs(appVersion).join('\n');
    expect(text, contains('codeforge-$appVersion-sources.tar.'));
    expect(text, contains('$releasesUrl:'));
    expect(text, contains('at least three years'));
    expect(text, endsWith('open an issue at $issuesUrl.'));
  });

  test("the bundled license is the repository's LICENSE", () {
    expect(
      File(codeForgeLicenseAsset).readAsStringSync(),
      File('../LICENSE').readAsStringSync(),
    );
  });
}
