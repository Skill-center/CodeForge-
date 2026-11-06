import 'package:codeforge/core/editor/languages.dart';
import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/editor/rate_limiter.dart';
import 'package:codeforge/core/editor/shadow_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShadowDocument', () {
    ShadowDocument shadow() =>
        ShadowDocument(docId: 'd1', language: 'javascript', text: 'ab\ncd');

    test('applies a change that follows on and bumps the version', () {
      final doc = shadow();
      final refused = doc.applyChange(
        baseVersion: 0,
        version: 1,
        lengthBefore: 5,
        lengthAfter: 6,
        changes: [
          2,
          [0, 'X'],
          3,
        ],
      );
      expect(refused, isNull);
      expect(doc.text, 'abX\ncd');
      expect(doc.version, 1);
    });

    test('refuses anything that does not follow on, unchanged', () {
      final cases = <String, Map<String, Object>>{
        'stale base': {'base': 3, 'version': 4, 'before': 5, 'after': 6},
        'skipped version': {'base': 0, 'version': 2, 'before': 5, 'after': 6},
        'wrong length before': {
          'base': 0,
          'version': 1,
          'before': 4,
          'after': 5,
        },
        'wrong length after': {
          'base': 0,
          'version': 1,
          'before': 5,
          'after': 9,
        },
      };
      for (final MapEntry(key: name, value: c) in cases.entries) {
        final doc = shadow();
        final refused = doc.applyChange(
          baseVersion: c['base']! as int,
          version: c['version']! as int,
          lengthBefore: c['before']! as int,
          lengthAfter: c['after']! as int,
          changes: [
            2,
            [0, 'X'],
            3,
          ],
        );
        expect(refused, isNotNull, reason: name);
        expect(doc.text, 'ab\ncd', reason: name);
        expect(doc.version, 0, reason: name);
      }
    });

    test('refuses a change set that does not cover the text', () {
      final doc = shadow();
      final refused = doc.applyChange(
        baseVersion: 0,
        version: 1,
        lengthBefore: 5,
        lengthAfter: 4,
        changes: [4],
      );
      expect(refused, isNotNull);
      expect(doc.text, 'ab\ncd');
    });

    test('resync takes the editor text as authoritative', () {
      final doc = shadow()..resync(text: 'fresh', version: 7);
      expect(doc.text, 'fresh');
      expect(doc.version, 7);
    });

    test('selections clamp to the text', () {
      const selection = EditorSelection(anchor: 9, head: 2);
      final clamped = selection.clampedTo(4);
      expect(clamped.anchor, 4);
      expect(clamped.head, 2);
      expect(clamped.toJson(), {'anchor': 4, 'head': 2});
    });
  });

  group('languageForPath', () {
    test('maps known extensions, case-insensitively', () {
      expect(languageForPath('main.js'), 'javascript');
      expect(languageForPath('src/App.TSX'), 'tsx');
      expect(languageForPath('tool/run.mjs'), 'javascript');
      expect(languageForPath('app.py'), 'python');
      expect(languageForPath('README.md'), 'markdown');
      expect(languageForPath('site/index.htm'), 'html');
      expect(languageForPath('data.json'), 'json');
      expect(languageForPath('style.css'), 'css');
    });

    test('knows configuration files by their whole name', () {
      expect(languageForPath('.babelrc'), 'json');
      expect(languageForPath('config/.eslintrc'), 'json');
      expect(languageForPath('site.webmanifest'), 'json');
      expect(languageForPath('types.pyi'), 'python');
    });

    test('reads the shebang of a file without a known extension', () {
      String lang(String firstLine) =>
          languageForPath('bin/tool', firstLine: firstLine);
      expect(lang('#!/usr/bin/env node'), 'javascript');
      expect(lang('#!/usr/local/bin/node --harmony'), 'javascript');
      expect(lang('#!/usr/bin/env bun'), 'javascript');
      expect(lang('#!/usr/bin/env -S deno run --allow-net'), 'typescript');
      expect(lang('#!/usr/bin/env ts-node'), 'typescript');
      expect(lang('#!/usr/bin/python3 -u'), 'python');
      expect(lang('#!/usr/bin/env python3.12'), 'python');
      expect(lang('#!/usr/bin/env PYTHONUNBUFFERED=1 pypy3'), 'python');
      expect(lang('#!/bin/sh'), 'plaintext');
      expect(lang('#!/usr/bin/env'), 'plaintext');
      expect(lang('#!'), 'plaintext');
      expect(lang('// not a shebang'), 'plaintext');
    });

    test('an extension wins over a shebang; .txt stays plain', () {
      expect(
        languageForPath('run.py', firstLine: '#!/usr/bin/env node'),
        'python',
      );
      expect(
        languageForPath('notes.txt', firstLine: '#!/usr/bin/env node'),
        'plaintext',
      );
    });

    test('falls back to plain text', () {
      expect(languageForPath('Makefile'), 'plaintext');
      expect(languageForPath('.gitignore'), 'plaintext');
      expect(languageForPath('notes.txt'), 'plaintext');
      expect(languageForPath('archive.tar.gz'), 'plaintext');
    });

    test('only names languages the page knows', () {
      for (final language in [
        ...editorLanguageByExtension.values,
        ...editorLanguageByFileName.values,
        ...editorLanguageByInterpreter.values,
      ]) {
        expect(editorLanguageIds, contains(language));
      }
      expect(editorLanguageIds, contains('plaintext'));
    });
  });

  group('MessageRateLimiter', () {
    test('allows a burst, then refills over time', () {
      var now = 0;
      final limiter = MessageRateLimiter(
        capacity: 3,
        refillPerSecond: 2,
        nowMicros: () => now,
      );
      expect(
        [for (var i = 0; i < 4; i++) limiter.tryAcquire()],
        [true, true, true, false],
      );
      now += Duration.microsecondsPerSecond ~/ 2; // one token back
      expect(limiter.tryAcquire(), isTrue);
      expect(limiter.tryAcquire(), isFalse);
      now += 10 * Duration.microsecondsPerSecond; // refills to capacity only
      expect(
        [for (var i = 0; i < 4; i++) limiter.tryAcquire()],
        [true, true, true, false],
      );
    });
  });
}
