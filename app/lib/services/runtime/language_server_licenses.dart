/// The language servers' licence texts, for the app's licence page (Phase 6
/// W2; docs/adr/0015-language-servers.md).
///
/// runtime/language_servers.py writes [languageServerLicensesAsset] from the
/// licence files of the servers' npm packages and of the packages bundled
/// inside them, the same packages THIRD_PARTY_NOTICES.md §6 lists, and CI
/// checks it against the pins. It has the userland file's format, so the
/// same parser reads it. Registered with `LicenseRegistry` at startup
/// (About → Open-source licenses).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'userland_licenses.dart';

/// The file runtime/language_servers.py writes.
const String languageServerLicensesAsset =
    'assets/licenses/language-servers.txt';

/// [languageServerLicenses] from the app's own bundle, for
/// `LicenseRegistry.addLicense` at startup.
Stream<LicenseEntry> bundledLanguageServerLicenses() =>
    languageServerLicenses(rootBundle);

/// The entries of [languageServerLicensesAsset] in [bundle]: none when the
/// file is missing or malformed. The tests hold the bundled file to the
/// format.
Stream<LicenseEntry> languageServerLicenses(AssetBundle bundle) async* {
  final List<LicenseEntry> entries;
  try {
    entries = parseLanguageServerLicenses(
      await bundle.loadString(languageServerLicensesAsset, cache: false),
    );
  } on Object {
    return;
  }
  yield* Stream.fromIterable(entries);
}

/// The language servers' file, parsed as the userland's is.
List<LicenseEntry> parseLanguageServerLicenses(String text) =>
    parseUserlandLicenses(text, scope: 'the language servers', filesIn: '');
