/// The language servers as Settings names them (Phase 6 W5): each server's
/// packages and versions are the ones the runtime ships, pinned in
/// runtime/language-servers/package.json.
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("each server's packages are the pinned ones, and every pinned "
      'package is a server\'s', () {
    // `flutter test` runs with the package root (app/) as working directory.
    final manifest =
        jsonDecode(
              File(
                '../runtime/language-servers/package.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final pinned = manifest['dependencies']! as Map<String, Object?>;
    for (final server in LspServerId.values) {
      for (final MapEntry(key: name, value: version)
          in server.packages.entries) {
        expect(pinned[name], version, reason: '${server.id}: $name');
      }
    }
    expect({
      for (final server in LspServerId.values) ...server.packages.keys,
    }, pinned.keys.toSet());
  });

  test('what Settings says runs', () {
    expect(LspServerId.pyright.versions, 'pyright 1.1.414');
    expect(LspServerId.pyright.language, 'Python');
    expect(
      LspServerId.typescript.versions,
      'typescript 6.0.3, typescript-language-server 6.1.0',
    );
  });
}
