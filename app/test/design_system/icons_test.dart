/// The bundled icon fonts against the code that names their glyphs
/// (docs/UI_DESIGN_SYSTEM.md §6, Phase 3 W4): each font holds exactly the
/// codepoints its Dart file declares, so a missing glyph fails here instead
/// of drawing as a blank square. The scripts in tool/fonts/ rebuild them.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:codeforge/design_system/tokens/file_glyphs.dart';
import 'package:codeforge/design_system/tokens/icons.dart';
import 'package:flutter_test/flutter_test.dart';

/// The codepoints a TrueType font maps to a glyph, read from its `cmap`
/// table (formats 4 and 12, which is what the build scripts write).
Set<int> _mappedCodepoints(String path) {
  final data = ByteData.sublistView(File(path).readAsBytesSync());
  final tables = data.getUint16(4);
  int? cmap;
  for (var i = 0; i < tables; i++) {
    final record = 12 + 16 * i;
    final tag = String.fromCharCodes(
      data.buffer.asUint8List(data.offsetInBytes + record, 4),
    );
    if (tag == 'cmap') cmap = data.getUint32(record + 8);
  }
  if (cmap == null) throw StateError('$path has no cmap table');
  final found = <int>{};
  final subtables = data.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final at = cmap + data.getUint32(cmap + 4 + 8 * i + 4);
    switch (data.getUint16(at)) {
      case 4:
        final segments = data.getUint16(at + 6) ~/ 2;
        final ends = at + 14;
        final starts = ends + 2 * segments + 2;
        final deltas = starts + 2 * segments;
        final ranges = deltas + 2 * segments;
        for (var s = 0; s < segments; s++) {
          final start = data.getUint16(starts + 2 * s);
          final end = data.getUint16(ends + 2 * s);
          final delta = data.getUint16(deltas + 2 * s);
          final range = data.getUint16(ranges + 2 * s);
          for (var c = start; c <= end && c != 0xffff; c++) {
            final int glyph;
            if (range == 0) {
              glyph = (c + delta) & 0xffff;
            } else {
              final raw = data.getUint16(
                ranges + 2 * s + range + 2 * (c - start),
              );
              glyph = raw == 0 ? 0 : (raw + delta) & 0xffff;
            }
            if (glyph != 0) found.add(c);
          }
        }
      case 12:
        final groups = data.getUint32(at + 12);
        for (var g = 0; g < groups; g++) {
          final group = at + 16 + 12 * g;
          final start = data.getUint32(group);
          final end = data.getUint32(group + 4);
          final first = data.getUint32(group + 8);
          for (var c = start; c <= end; c++) {
            if (first + (c - start) != 0) found.add(c);
          }
        }
    }
  }
  return found;
}

/// The codepoints a Dart file declares as `IconData(0x…`.
Set<int> _declared(String path) => RegExp(r'IconData\(\s*0x([0-9a-f]+)')
    .allMatches(File(path).readAsStringSync())
    .map((m) => int.parse(m.group(1)!, radix: 16))
    .toSet();

void main() {
  group('the icon fonts hold exactly the declared codepoints', () {
    for (final (font, source, family) in [
      (
        'assets/fonts/MaterialSymbolsRounded.ttf',
        'lib/design_system/tokens/icons.dart',
        CfIcons.fontFamily,
      ),
      (
        'assets/fonts/CfFileGlyphs.ttf',
        'lib/design_system/tokens/file_glyphs.dart',
        CfFileGlyphs.fontFamily,
      ),
    ]) {
      test(family, () {
        final declared = _declared(source);
        final mapped = _mappedCodepoints(font);
        expect(declared, isNotEmpty);
        expect(
          declared.difference(mapped).map((c) => c.toRadixString(16)),
          isEmpty,
          reason:
              '$source declares codepoints $font lacks: re-run the '
              'script in tool/fonts/',
        );
        expect(
          mapped.difference(declared).map((c) => c.toRadixString(16)),
          isEmpty,
          reason: '$font holds codepoints $source no longer declares',
        );
      });
    }

    test('pubspec.yaml declares both families with their files', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec,
        contains(
          '- family: MaterialSymbolsRounded\n'
          '      fonts:\n'
          '        - asset: assets/fonts/MaterialSymbolsRounded.ttf',
        ),
      );
      expect(
        pubspec,
        contains(
          '- family: CfFileGlyphs\n'
          '      fonts:\n'
          '        - asset: assets/fonts/CfFileGlyphs.ttf',
        ),
      );
    });

    test('every file glyph is in the gallery list, once', () {
      expect(
        CfFileGlyphs.all.values.map((g) => g.codePoint).toSet(),
        _declared('lib/design_system/tokens/file_glyphs.dart'),
      );
      expect(CfFileGlyphs.all, hasLength(21));
    });
  });

  group('CfFileGlyphs.forName', () {
    test('reads the extension after the last dot, in any case', () {
      expect(CfFileGlyphs.forName('main.dart'), CfFileGlyphs.dart);
      expect(CfFileGlyphs.forName('App.TSX'), CfFileGlyphs.typescript);
      expect(CfFileGlyphs.forName('jquery.min.js'), CfFileGlyphs.javascript);
      expect(CfFileGlyphs.forName('build.gradle.kts'), CfFileGlyphs.kotlin);
      expect(CfFileGlyphs.forName('pubspec.yaml'), CfFileGlyphs.yaml);
      expect(CfFileGlyphs.forName('ci.yml'), CfFileGlyphs.yaml);
      expect(CfFileGlyphs.forName('README.md'), CfFileGlyphs.markdown);
      expect(CfFileGlyphs.forName('index.htm'), CfFileGlyphs.markup);
      expect(CfFileGlyphs.forName('AndroidManifest.xml'), CfFileGlyphs.markup);
      expect(CfFileGlyphs.forName('theme.scss'), CfFileGlyphs.css);
      expect(CfFileGlyphs.forName('vector.hpp'), CfFileGlyphs.cFamily);
      expect(CfFileGlyphs.forName('Main.java'), CfFileGlyphs.java);
      expect(CfFileGlyphs.forName('main.go'), CfFileGlyphs.go);
      expect(CfFileGlyphs.forName('lib.rs'), CfFileGlyphs.rust);
      expect(CfFileGlyphs.forName('app.py'), CfFileGlyphs.python);
      expect(CfFileGlyphs.forName('run.sh'), CfFileGlyphs.shell);
      expect(CfFileGlyphs.forName('Cargo.toml'), CfFileGlyphs.config);
      expect(CfFileGlyphs.forName('notes.txt'), CfFileGlyphs.text);
      expect(CfFileGlyphs.forName('icon.PNG'), CfFileGlyphs.image);
      expect(CfFileGlyphs.forName('pubspec.lock'), CfFileGlyphs.lock);
      expect(CfFileGlyphs.forName('package.json'), CfFileGlyphs.json);
    });

    test('whole names win over extensions', () {
      expect(CfFileGlyphs.forName('.gitignore'), CfFileGlyphs.git);
      expect(CfFileGlyphs.forName('.bashrc'), CfFileGlyphs.shell);
      expect(CfFileGlyphs.forName('.babelrc'), CfFileGlyphs.json);
      expect(CfFileGlyphs.forName('LICENSE'), CfFileGlyphs.text);
      expect(CfFileGlyphs.forName('.env'), CfFileGlyphs.config);
      expect(CfFileGlyphs.forName('.env.local'), CfFileGlyphs.config);
    });

    test('anything else is a generic page', () {
      expect(CfFileGlyphs.forName('Makefile'), CfFileGlyphs.file);
      expect(CfFileGlyphs.forName('archive.zip'), CfFileGlyphs.file);
      expect(CfFileGlyphs.forName('.DS_Store'), CfFileGlyphs.file);
      expect(CfFileGlyphs.forName('trailing.'), CfFileGlyphs.file);
    });
  });
}
