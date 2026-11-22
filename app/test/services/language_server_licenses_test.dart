/// The language servers' licence texts on the licence page (Phase 6 W2):
/// runtime/language_servers.py's file, parsed into one entry per text.
library;

import 'package:codeforge/services/runtime/language_server_licenses.dart';
import 'package:codeforge/services/runtime/userland_licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String _text(LicenseEntry entry) =>
    entry.paragraphs.map((paragraph) => paragraph.text).join('\n');

/// A bundle without the file.
class _EmptyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) =>
      Future<ByteData>.error(FlutterError('no $key in this bundle'));
}

void main() {
  test('an entry names the language servers and where its file is', () {
    final entries = parseLanguageServerLicenses(
      [
        "CodeForge's language servers: the licence texts their packages carry.",
        userlandEntrySeparator,
        'Packages: vscode-jsonrpc 9.0.1',
        'Files: vscode-jsonrpc@9.0.1/License.txt (bundled in pyright@1.1.414)',
        '',
        'Copyright (c) Microsoft Corporation',
        '',
      ].join('\n'),
    );
    expect(entries, hasLength(1));
    expect(entries.single.packages, ['vscode-jsonrpc']);
    final text = _text(entries.single);
    expect(text, contains('In the language servers: vscode-jsonrpc 9.0.1.'));
    expect(
      text,
      contains(
        'at vscode-jsonrpc@9.0.1/License.txt (bundled in pyright@1.1.414):',
      ),
    );
    expect(text, isNot(contains('userland')));
  });

  test('a bundle without the file gives no entries', () async {
    expect(await languageServerLicenses(_EmptyBundle()).toList(), isEmpty);
  });

  test('the bundled file is well formed and covers the servers', () async {
    final text = await rootBundle.loadString(languageServerLicensesAsset);
    final entries = parseLanguageServerLicenses(text);
    final packages = {for (final entry in entries) ...entry.packages};
    expect(
      packages,
      containsAll(<String>[
        'pyright',
        'typescript',
        'typescript-language-server',
        'vscode-jsonrpc',
      ]),
    );
  });
}
