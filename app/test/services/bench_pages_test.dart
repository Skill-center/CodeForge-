/// The benchmark pages are verified like the editor page before anything
/// runs them, and their absence is a normal state (most builds have none).
library;

import 'dart:convert';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/editor/bench/bench_pages.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Assets from memory; anything else is missing.
final class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(this.files);

  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) {
      throw StateError('Unable to load asset: $key');
    }
    return ByteData.sublistView(utf8.encode(text));
  }
}

String _manifest(Map<String, Object?> pages) =>
    jsonEncode({'schema': 1, 'pages': pages});

Map<String, Object?> _entry(String file, String sha) => {
  'file': file,
  'engineVersion': '1.0.0',
  'bytes': 10,
  'gzipBytes': 5,
  'sha256': sha,
};

void main() {
  const html = '<!doctype html><p>bench</p>';
  final digest = sha256.convert(utf8.encode(html)).toString();

  group('parseBenchManifest', () {
    test('lists the pages in manifest order', () {
      final pages = parseBenchManifest(
        _manifest({
          'codemirror': _entry('codemirror.html', 'a'),
          'monaco': _entry('monaco.html', 'b'),
        }),
      ).orThrow;
      expect([for (final p in pages) p.engine], ['codemirror', 'monaco']);
      expect(pages.first.file, 'codemirror.html');
      expect(pages.last.toJson()['gzipBytes'], 5);
    });

    test('refuses malformed manifests', () {
      for (final text in [
        'not json',
        '[]',
        jsonEncode({'schema': 1}),
        _manifest({'monaco': 'monaco.html'}),
        _manifest({
          'monaco': {..._entry('monaco.html', 'b'), 'bytes': '10'},
        }),
        // A page must sit next to the manifest, nowhere else.
        _manifest({'monaco': _entry('../editor/editor.html', 'b')}),
      ]) {
        expect(parseBenchManifest(text).isOk, isFalse, reason: text);
      }
    });
  });

  group('verifyBenchPage', () {
    final info = parseBenchManifest(
      _manifest({'monaco': _entry('monaco.html', digest)}),
    ).orThrow.single;

    test('accepts a page that matches its manifest', () {
      final page = verifyBenchPage(info, utf8.encode(html)).orThrow;
      expect(page.html, html);
      expect(page.info.engine, 'monaco');
    });

    test('refuses a page changed by a single byte', () {
      final result = verifyBenchPage(info, [...utf8.encode(html), 0x20]);
      expect(result.failureOrNull?.message, contains('does not match'));
    });
  });

  group('loading from the bundle', () {
    test('a build without benchmark pages lists none', () async {
      final pages = (await loadBenchManifest(_MemoryBundle({}))).orThrow;
      expect(pages, isEmpty);
    });

    test('loads and verifies a bundled page', () async {
      final bundle = _MemoryBundle({
        benchManifestAsset: _manifest({
          'codemirror': _entry('codemirror.html', digest),
        }),
        '${benchAssetDir}codemirror.html': html,
      });
      final info = (await loadBenchManifest(bundle)).orThrow.single;
      final page = (await loadBenchPage(bundle, info)).orThrow;
      expect(page.html, html);
    });

    test('a listed but missing page is a storage failure', () async {
      final bundle = _MemoryBundle({
        benchManifestAsset: _manifest({
          'monaco': _entry('monaco.html', digest),
        }),
      });
      final info = (await loadBenchManifest(bundle)).orThrow.single;
      final result = await loadBenchPage(bundle, info);
      expect(result.failureOrNull, isA<StorageFailure>());
    });

    test('licences: none without pages, one entry per package', () async {
      expect(await benchLicenses(_MemoryBundle({})).toList(), isEmpty);
      final notices = [
        'monaco-editor 0.57.0 (MIT)\n\nMIT text',
        '-' * 72,
        'crelt 1.0.7 (MIT)\n\nMore MIT text',
      ].join('\n');
      final entries = await benchLicenses(
        _MemoryBundle({benchNoticesAsset: notices}),
      ).toList();
      expect(
        [for (final e in entries) e.packages.single],
        ['monaco-editor', 'crelt'],
      );
    });
  });
}
