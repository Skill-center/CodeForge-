/// The Linux userland's licence texts on the licence page (Phase 5 W1):
/// runtime/notices.py's file, parsed into one entry per text.
library;

import 'package:codeforge/services/runtime/userland_licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A file as runtime/notices.py writes one: a preamble, then the entries.
String _file(List<String> entries) {
  final lines = [
    "CodeForge's Linux userland: the licence texts its Termux packages carry.",
    '',
    'Written by runtime/notices.py.',
    for (final entry in entries) ...[userlandEntrySeparator, entry],
  ];
  return '${lines.join('\n')}\n';
}

String _text(LicenseEntry entry) =>
    entry.paragraphs.map((paragraph) => paragraph.text).join('\n');

/// A bundle without the file.
class _EmptyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) =>
      Future<ByteData>.error(FlutterError('no $key in this bundle'));
}

void main() {
  test('each entry lists its packages, the paths and the text', () {
    final entries = parseUserlandLicenses(
      _file([
        'Packages: bash 5.3.9, coreutils 9.9\n'
            'Files: share/LICENSES/GPL-3.0.txt\n'
            '\n'
            '                    GNU GENERAL PUBLIC LICENSE\n'
            '                       Version 3, 29 June 2007\n'
            '\n'
            ' Everyone is permitted to copy and distribute verbatim copies',
        'Packages: libcurl 8.11.0, libcurl 8.12.0\n'
            'Files: share/doc/libcurl/copyright\n'
            '\n'
            'COPYRIGHT AND PERMISSION NOTICE',
      ]),
    );
    expect(entries, hasLength(2));
    expect(entries.first.packages, ['bash', 'coreutils']);
    final gpl = _text(entries.first);
    expect(gpl, contains('In the Linux userland: bash 5.3.9, coreutils 9.9.'));
    expect(gpl, contains('at share/LICENSES/GPL-3.0.txt in the userland'));
    expect(gpl, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(gpl, contains('Everyone is permitted to copy'));
    // A package in two versions (one per ABI) is listed once.
    expect(entries.last.packages, ['libcurl']);
    expect(_text(entries.last), contains('COPYRIGHT AND PERMISSION NOTICE'));
  });

  test('the preamble alone holds no entries', () {
    expect(parseUserlandLicenses(_file([])), isEmpty);
  });

  test('an entry without its header lines or its text is refused', () {
    for (final broken in [
      'Files: share/doc/a/copyright\n\ntext',
      'Packages: a 1\nFiles: share/doc/a/copyright\ntext',
      'Packages: a 1\nFiles: share/doc/a/copyright\n\n',
      'Packages: a 1\n\ntext\nmore',
    ]) {
      expect(
        () => parseUserlandLicenses(_file([broken])),
        throwsFormatException,
        reason: broken,
      );
    }
  });

  test('a bundle without the file gives no entries', () async {
    expect(await userlandLicenses(_EmptyBundle()).toList(), isEmpty);
  });

  test('the bundled file is well formed and covers the userland', () async {
    final text = await rootBundle.loadString(userlandLicensesAsset);
    final entries = parseUserlandLicenses(text);
    // Until CI's first commit-back run writes it, the file is a placeholder.
    if (!text.contains('Not written yet')) {
      final packages = {for (final entry in entries) ...entry.packages};
      expect(
        packages,
        containsAll(<String>['bash', 'coreutils', 'git', 'nodejs', 'python']),
      );
    }
  });
}
