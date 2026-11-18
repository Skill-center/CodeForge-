/// The userland's licence texts, for the app's licence page (Phase 5 W1).
///
/// runtime/notices.py writes [userlandLicensesAsset] from the pinned
/// packages' own licence files, the same files THIRD_PARTY_NOTICES.md §5
/// lists, and CI checks it against the pins. Each distinct text appears
/// once, after the packages that carry it. Registered with `LicenseRegistry`
/// at startup, next to the editor page's (About → Open-source licenses).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The file runtime/notices.py writes.
const String userlandLicensesAsset = 'assets/licenses/userland.txt';

/// The line between entries: runtime/notices.py's `ENTRY_SEPARATOR`, which
/// no licence text contains (notices.py checks that when it writes the file).
final String userlandEntrySeparator = '\u2500' * 72;

const String _packagesPrefix = 'Packages: ';
const String _filesPrefix = 'Files: ';

/// [userlandLicenses] from the app's own bundle, for
/// `LicenseRegistry.addLicense` at startup.
Stream<LicenseEntry> bundledUserlandLicenses() => userlandLicenses(rootBundle);

/// The entries of [userlandLicensesAsset] in [bundle]: none when the file is
/// missing or malformed. The tests hold the bundled file to the format.
Stream<LicenseEntry> userlandLicenses(AssetBundle bundle) async* {
  final List<LicenseEntry> entries;
  try {
    entries = parseUserlandLicenses(
      await bundle.loadString(userlandLicensesAsset, cache: false),
    );
  } on Object {
    return;
  }
  yield* Stream.fromIterable(entries);
}

/// One entry per licence text, listed under each package that carries it.
///
/// The text before the first separator is the file's preamble. Each entry
/// after one is a `Packages: name version, ...` line, a `Files: path, ...`
/// line (the text's paths in the payload), an empty line, then the text.
/// Anything else is a [FormatException].
List<LicenseEntry> parseUserlandLicenses(String text) {
  final entries = <LicenseEntry>[];
  for (final section in text.split('\n$userlandEntrySeparator\n').skip(1)) {
    final lines = section.split('\n');
    if (lines.length < 4 ||
        !lines[0].startsWith(_packagesPrefix) ||
        !lines[1].startsWith(_filesPrefix) ||
        lines[2].isNotEmpty) {
      throw FormatException(
        'a userland licence entry without its two header lines',
        section,
      );
    }
    final packages = lines[0].substring(_packagesPrefix.length).split(', ');
    final names = <String>{
      for (final package in packages) package.split(' ').first,
    };
    final files = lines[1].substring(_filesPrefix.length);
    final body = lines.sublist(3).join('\n').trimRight();
    if (names.any((name) => name.isEmpty) || files.isEmpty || body.isEmpty) {
      throw FormatException('a userland licence entry without a text', section);
    }
    entries.add(
      LicenseEntryWithLineBreaks(
        names.toList(),
        'In the Linux userland: ${packages.join(', ')}. '
        'The text, at $files in the userland:\n\n$body',
      ),
    );
  }
  return entries;
}
