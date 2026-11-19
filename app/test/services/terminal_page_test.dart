/// The terminal page is verified against its manifest before it runs
/// (Phase 5 W3, docs/SECURITY.md §3), and its packages' notices reach the
/// licence page.
library;

import 'dart:convert';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/terminal/terminal_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String _manifest(String sha, {Object? protocol = 1}) => jsonEncode({
  'schema': 1,
  'protocol': protocol,
  'engine': 'xterm',
  'engineVersion': '6.0.0',
  'html': {'file': 'terminal.html', 'sha256': sha},
});

final class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);

  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) {
      throw StateError('missing $key');
    }
    final bytes = Uint8List.fromList(utf8.encode(text));
    return ByteData.sublistView(bytes);
  }
}

void main() {
  final page = utf8.encode('<!doctype html><title>terminal</title>');
  final digest = sha256.convert(page).toString();

  test('a page that matches its manifest is accepted', () {
    final verified = verifyTerminalPage(page, _manifest(digest)).orThrow;
    expect(verified.sha256, digest);
    expect(verified.engineVersion, '6.0.0');
    expect(verified.protocol, 1);
    expect(verified.html, contains('<title>terminal</title>'));
  });

  test('one changed byte is refused', () {
    final result = verifyTerminalPage([...page, 0x20], _manifest(digest));
    expect(result.isOk, isFalse);
    expect(result.failureOrNull, isA<BridgeFailure>());
  });

  test('a malformed manifest is refused', () {
    expect(verifyTerminalPage(page, 'not json').isOk, isFalse);
    expect(verifyTerminalPage(page, '[]').isOk, isFalse);
    expect(
      verifyTerminalPage(page, _manifest(digest, protocol: '1')).isOk,
      isFalse,
    );
  });

  test('loading reads the page and the manifest from the bundle', () async {
    final bundle = _Bundle({
      terminalPageAsset: utf8.decode(page),
      terminalManifestAsset: _manifest(digest),
    });
    expect((await loadTerminalPage(bundle)).isOk, isTrue);
    final missing = await loadTerminalPage(_Bundle({}));
    expect(missing.failureOrNull, isA<StorageFailure>());
  });

  test('the notices become one licence entry per package', () async {
    final notices = [
      '@xterm/addon-fit 0.11.0 (MIT)\n\nMIT text one',
      '@xterm/xterm 6.0.0 (MIT)\n\nMIT text two',
    ].join('\n${'-' * 72}\n\n');
    final entries = await terminalLicenses(
      _Bundle({terminalNoticesAsset: notices}),
    ).toList();
    expect(
      [for (final entry in entries) entry.packages.single],
      ['@xterm/addon-fit', '@xterm/xterm'],
    );
    expect(await terminalLicenses(_Bundle({})).toList(), isEmpty);
  });
}
