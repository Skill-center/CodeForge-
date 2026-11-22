/// The capability model (spec §6.5, docs/RUNTIME_INTEGRATION.md §3; Phase 4
/// W4): which language a file is for its capabilities, shell scripts
/// included (and Ruby and Perl since Phase 5 W4), and what the runtime's
/// readiness flips.
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

  test('Ruby and Perl scripts are languages here too (Phase 5 W4)', () {
    expect(capabilityLanguageFor('tool.rb'), rubyLanguage);
    expect(capabilityLanguageFor('lib/Report.PL'), perlLanguage);
    expect(
      capabilityLanguageFor('bin/report', firstLine: '#!/usr/bin/env perl'),
      perlLanguage,
    );
    expect(
      capabilityLanguageFor('bin/serve', firstLine: '#!/usr/bin/ruby -w'),
      rubyLanguage,
    );
    expect(
      capabilityLanguageFor('notes.txt', firstLine: '#!/usr/bin/env ruby'),
      plainTextLanguage,
    );
    // The editor still shows them as plain text; the status strip names
    // them itself.
    expect(languageForPath('tool.rb'), plainTextLanguage);
    expect(runtimeOnlyLanguages, {shellLanguage, rubyLanguage, perlLanguage});
    expect(runtimeLanguageNames.keys, runtimeInterpreters.keys);
  });

  test('every language the runtime runs turns executable once ready', () {
    for (final language in runtimeInterpreters.keys) {
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
    expect(
      capabilitiesOf('javascript', runtimeReady: true).interpreter,
      'node',
    );
    expect(capabilitiesOf('python', runtimeReady: true).interpreter, 'python');
    expect(
      capabilitiesOf(shellLanguage, runtimeReady: true).interpreter,
      'bash',
    );
    expect(
      capabilitiesOf(rubyLanguage, runtimeReady: true).interpreter,
      'ruby',
    );
    expect(
      capabilitiesOf(perlLanguage, runtimeReady: true).interpreter,
      'perl',
    );
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

  test('a language is analyzable while its server runs (Phase 6 W4)', () {
    for (final language in ['python', 'javascript', 'typescript', 'tsx']) {
      expect(
        capabilitiesOf(language, runtimeReady: true).analyzable,
        isFalse,
        reason: language,
      );
      final running = capabilitiesOf(
        language,
        runtimeReady: true,
        analyzable: true,
      );
      expect(running.analyzable, isTrue, reason: language);
      expect(running.editable, isTrue, reason: language);
    }
  });
}
