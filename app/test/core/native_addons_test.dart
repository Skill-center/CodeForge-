/// The native-addon limitation (Phase 5 W4): a native build failing for
/// want of a compiler is spotted in a session's output, once.
library;

import 'package:codeforge/core/terminal/native_addons.dart';
import 'package:flutter_test/flutter_test.dart';

NativeAddonKind? _spot(List<String> chunks) {
  final detector = NativeAddonDetector();
  NativeAddonKind? found;
  for (final chunk in chunks) {
    found ??= detector.feed(chunk);
  }
  return found;
}

void main() {
  test('npm: node-gyp and prebuild failing', () {
    expect(
      _spot(['npm error gyp ERR! stack Error: not found: make\r\n']),
      NativeAddonKind.npm,
    );
    // npm colours each word.
    expect(
      _spot([
        '\x1b[37;40mgyp\x1b[0m \x1b[0m\x1b[31;40mERR!\x1b[0m find Python',
      ]),
      NativeAddonKind.npm,
    );
    expect(
      _spot([
        'prebuild-install warn install No prebuilt binaries found '
            '(target=26.13.1 runtime=node arch=arm64 platform=android)',
      ]),
      NativeAddonKind.npm,
    );
  });

  test('pip: a C extension with no compiler', () {
    expect(
      _spot([
        "error: command 'aarch64-linux-android-clang' failed: No such file "
            'or directory',
      ]),
      NativeAddonKind.pip,
    );
    expect(
      _spot(['  ERROR: Failed building wheel for numpy\n']),
      NativeAddonKind.pip,
    );
    expect(
      _spot(['fatal error: Python.h: No such file or directory']),
      NativeAddonKind.pip,
    );
  });

  test('a compiler called and not there', () {
    expect(_spot(['bash: gcc: command not found\n']), NativeAddonKind.compiler);
    expect(
      _spot(['configure: error: C compiler cannot create executables']),
      NativeAddonKind.compiler,
    );
  });

  test('a line split across chunks still counts', () {
    expect(_spot(['npm error gy', 'p ERR! build error']), NativeAddonKind.npm);
  });

  test('ordinary output is no such failure, and a second one is quiet', () {
    expect(
      _spot([
        'added 12 packages in 3s\n',
        'Successfully installed requests-2.32.3\n',
        'bash: frobnicate: command not found\n',
      ]),
      isNull,
    );
    final detector = NativeAddonDetector();
    expect(detector.feed('gyp ERR! one'), NativeAddonKind.npm);
    expect(detector.feed('gyp ERR! two'), isNull);
    expect(detector.found, NativeAddonKind.npm);
  });

  test('each kind says why, and what works', () {
    expect(
      nativeAddonMessage(NativeAddonKind.npm),
      contains('pure-JavaScript'),
    );
    expect(nativeAddonMessage(NativeAddonKind.pip), contains('pure-Python'));
    for (final kind in NativeAddonKind.values) {
      expect(nativeAddonMessage(kind), contains('no C compiler'));
      expect(nativeAddonMessage(kind), contains('Android 10 and later'));
      expect(nativeAddonMessage(kind), contains('app storage'));
      expect(nativeAddonMessage(kind), isNot(contains('wheel')));
    }
  });
}
