/// The URLs a clone may take (Phase 7 W3, gate G3): the same fixture the
/// Kotlin host's GitUrlsTest reads (test/fixtures/git/urls.tsv), so both
/// sides accept and refuse the same URLs; a refusal says why and never
/// repeats a secret; a clone's project is named after its repository.
library;

import 'dart:io';

import 'package:codeforge/core/git/git_urls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the fixture says which URLs are cloned, with their host', () {
    var accepted = 0;
    var refused = 0;
    for (final line in File('test/fixtures/git/urls.tsv').readAsLinesSync()) {
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final fields = line.split('\t');
      final url = fields.sublist(3).join('\t');
      final checked = checkRemoteUrl(url);
      switch (fields[0]) {
        case 'accept':
          expect(checked.problem, isNull, reason: url);
          expect(checked.url!.scheme, fields[1], reason: url);
          expect(checked.url!.host, fields[2], reason: url);
          accepted += 1;
        case 'refuse':
          expect(checked.url, isNull, reason: '${fields[1]}: $url');
          expect(checked.problem!.message, isNotEmpty);
          refused += 1;
        default:
          fail('not a verdict: $line');
      }
    }
    expect(accepted, greaterThanOrEqualTo(10));
    expect(refused, greaterThanOrEqualTo(20));
  });

  test('a refusal says why, and never repeats the secret', () {
    const token = 'ghp_0123456789abcdefghijklmnopqrstuvwxyzAB';
    for (final url in [
      'https://ada:$token@github.com/o/r.git',
      'https://$token@github.com/o/r.git',
      'https://github.com/o/r.git?t=$token',
    ]) {
      final message = checkRemoteUrl(url).problem!.message;
      expect(message, isNot(contains(token)));
    }
    expect(
      checkRemoteUrl('https://ada:x@github.com/o/r.git').problem!.message,
      contains('password'),
    );
    expect(
      checkRemoteUrl('https://$token@github.com/o/r.git').problem!.message,
      contains('token'),
    );
    expect(looksLikeToken('glpat-abc'), isTrue);
    expect(looksLikeToken('git'), isFalse);
    expect(looksLikeToken('ada.lovelace.analytical-engine'), isFalse);
  });

  test("a clone's project is named after its repository", () {
    expect(
      projectNameFromUrl('https://github.com/octocat/Hello-World.git'),
      'Hello-World',
    );
    expect(projectNameFromUrl('git@github.com:octocat/spoon-knife'), 'spoon-knife');
    expect(projectNameFromUrl('https://example.com/a/b/'), 'b');
    expect(projectNameFromUrl('  https://example.com/team/app.git  '), 'app');
    expect(projectNameFromUrl('https://example.com/x/.hidden.git'), 'hidden');
    expect(projectNameFromUrl('https://ada:pw@example.com/x/r.git'), isNull);
    expect(projectNameFromUrl('not a url'), isNull);
  });

  test('this device is the only plain-HTTP host', () {
    for (final host in ['127.0.0.1', '127.0.0.1:8080', 'localhost', '[::1]:9']) {
      expect(isLoopbackHost(host), isTrue, reason: host);
    }
    for (final host in ['github.com', '10.0.2.2', '127.0.0.256', '[::2]']) {
      expect(isLoopbackHost(host), isFalse, reason: host);
    }
  });
}
