/// The editor page is verified before anything runs it (docs/SECURITY.md §3).
/// The bundled-page tests need app/assets/editor/, which CI builds in the
/// editor job; locally, run `npm run build` in editor/ first.
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/editor/editor_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String _manifest(String sha, {Object? protocol = 1}) => jsonEncode({
  'schema': 1,
  'protocol': protocol,
  'engine': 'codemirror',
  'engineVersion': '6.43.15',
  'html': {'file': 'editor.html', 'sha256': sha},
});

void main() {
  group('verifyEditorPage', () {
    final page = utf8.encode('<!doctype html><p>editor</p>');
    final digest = sha256.convert(page).toString();

    test('accepts a page that matches its manifest', () {
      final verified = verifyEditorPage(page, _manifest(digest)).orThrow;
      expect(verified.html, '<!doctype html><p>editor</p>');
      expect(verified.sha256, digest);
      expect(verified.protocol, 1);
      expect(verified.engineVersion, '6.43.15');
    });

    test('refuses a page changed by a single byte', () {
      final result = verifyEditorPage([...page, 0x20], _manifest(digest));
      expect(result.failureOrNull?.message, contains('does not match'));
    });

    test('refuses malformed manifests', () {
      for (final manifest in [
        'not json',
        '[]',
        '{}',
        _manifest(digest, protocol: '1'),
      ]) {
        expect(
          verifyEditorPage(page, manifest).isOk,
          isFalse,
          reason: manifest,
        );
      }
    });

    test('refuses bytes that are not UTF-8', () {
      final bad = [0xFF, 0xFE, 0x00];
      final manifest = _manifest(sha256.convert(bad).toString());
      expect(verifyEditorPage(bad, manifest).isOk, isFalse);
    });
  });

  group('the bundled page', () {
    test('is present, verified and speaks protocol 1', () async {
      final result = await loadEditorPage(rootBundle);
      expect(
        result.isOk,
        isTrue,
        reason:
            '${result.failureOrNull?.message} '
            '(build it with `npm run build` in editor/)',
      );
      final page = result.orThrow;
      expect(page.protocol, 1);
      expect(page.html, startsWith('<!doctype html>'));
      // The bundle carries exactly what editor/tool/build.mjs wrote.
      final built = File('assets/editor/editor.html').readAsBytesSync();
      expect(page.sha256, sha256.convert(built).toString());
    });

    test('its notices list every bundled package', () async {
      final manifest =
          jsonDecode(await rootBundle.loadString(editorManifestAsset))
              as Map<String, Object?>;
      final packages = (manifest['packages']! as Map<String, Object?>).keys;
      final entries = parseEditorNotices(
        await rootBundle.loadString(editorNoticesAsset),
      );
      expect(
        [for (final entry in entries) ...entry.packages]..sort(),
        packages.toList()..sort(),
      );
      for (final entry in entries) {
        expect(
          entry.paragraphs.map((p) => p.text).join('\n'),
          contains('Permission'),
          reason: '${entry.packages.first} has a licence text',
        );
      }
    });
  });

  test('parseEditorNotices splits sections and keeps the licence text', () {
    final sample = [
      'a-pkg 1.0.0 (MIT)\n\nMIT License\n\nText A',
      'b-pkg 2.0.0 (ISC)\n\nISC License\n\nText B',
    ].join('\n${'-' * 72}\n\n');
    final entries = parseEditorNotices(sample);
    expect([for (final e in entries) e.packages.single], ['a-pkg', 'b-pkg']);
    expect(
      entries.last.paragraphs.map((p) => p.text).join('\n'),
      contains('Text B'),
    );
  });
}
