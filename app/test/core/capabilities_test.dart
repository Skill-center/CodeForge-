/// The capability model (spec §6.5, docs/RUNTIME_INTEGRATION.md §3; Phase 4
/// W4): which language a file is for its capabilities, shell scripts
/// included, and what the runtime's readiness flips.
library;

import 'package:codeforge/core/editor/capabilities.dart';
import 'package:codeforge/core/editor/languages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a shell script is a language here, by extension or #! line', () {
    expect(capabilityLanguageFor('run.sh'), shellLanguage);
    expect(capabilityLanguageFor('scripts/build.BASH'), shellLanguage);
    expect(
      capabilityLanguageFor('bin/deploy', firstLine: '#!/bin/sh'),
      shellLanguage,
    );
    expect(
      capabilityLanguageFor('bin/deploy', firstLine: '#!/usr/bin/env bash'),
      shellLanguage,
    );
    expect(
      capabilityLanguageFor('tool.conf', firstLine: '#! /bin/dash -e'),
      shellLanguage,
    );
    // The editor still shows them as plain text.
    expect(languageForPath('run.sh'), plainTextLanguage);
  });

  test('what is not a shell script stays what the editor says', () {
    // An extension the editor knows as plain text stays plain.
    expect(
      capabilityLanguageFor('notes.txt', firstLine: '#!/bin/sh'),
      plainTextLanguage,
    );
    // zsh is not in the runtime.
    expect(
      capabilityLanguageFor('tool', firstLine: '#!/usr/bin/env zsh'),
      plainTextLanguage,
    );
    expect(capabilityLanguageFor('.gitignore'), plainTextLanguage);
    expect(capabilityLanguageFor('main.py'), 'python');
    expect(
      capabilityLanguageFor('bin/serve', firstLine: '#!/usr/bin/env node'),
      'javascript',
    );
    expect(capabilityLanguageFor('README.md'), 'markdown');
    expect(shebangInterpreter('#!/usr/bin/env -S python3.12 -u'), 'python');
    expect(shebangInterpreter('#!'), isNull);
    expect(shebangInterpreter('echo'), isNull);
  });

  test('JavaScript, Python and shell turn executable once it is ready', () {
    for (final language in ['javascript', 'python', shellLanguage]) {
      final before = capabilitiesOf(language, runtimeReady: false);
      final after = capabilitiesOf(language, runtimeReady: true);
      expect(before.executable, isFalse, reason: language);
      expect(before.runnable, isTrue, reason: language);
      expect(after.executable, isTrue, reason: language);
      // Only the flag changes.
      expect(after.editable, isTrue);
      expect(after.analyzable, isFalse);
      expect(after.compilable, isFalse);
    }
    expect(capabilitiesOf('javascript', runtimeReady: true).interpreter, 'node');
    expect(capabilitiesOf('python', runtimeReady: true).interpreter, 'python');
    expect(capabilitiesOf(shellLanguage, runtimeReady: true).interpreter, 'bash');
  });

  test('every other language stays editable only', () {
    for (final language in [
      'typescript',
      'jsx',
      'tsx',
      'json',
      'html',
      'css',
      'markdown',
      plainTextLanguage,
    ]) {
      final capabilities = capabilitiesOf(language, runtimeReady: true);
      expect(capabilities.editable, isTrue, reason: language);
      expect(capabilities.executable, isFalse, reason: language);
      expect(capabilities.runnable, isFalse, reason: language);
      expect(capabilities.interpreter, isNull, reason: language);
    }
  });
}
