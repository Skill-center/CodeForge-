/// File-type glyphs (docs/UI_DESIGN_SYSTEM.md §6, Phase 3 W4): drawn for
/// CodeForge on a 16 dp grid with a 1.5 px stroke, for the 20 most common
/// kinds of file, and a generic page ([CfFileGlyphs.file]) for the rest.
///
/// They live in assets/fonts/CfFileGlyphs.ttf, which
/// tool/fonts/build_file_glyphs.py draws; its codepoints must match the
/// constants here (test/design_system/icons_test.dart checks the committed
/// font against this file). Glyphs are drawn at 16 dp in the explorer and
/// at any size elsewhere, like icons.
library;

import 'package:flutter/widgets.dart';

abstract final class CfFileGlyphs {
  /// The family the font is declared under in pubspec.yaml.
  static const String fontFamily = 'CfFileGlyphs';

  /// A page: any file no other glyph claims.
  static const IconData file = IconData(0xe000, fontFamily: fontFamily);

  /// A page with lines: plain text and logs.
  static const IconData text = IconData(0xe001, fontFamily: fontFamily);

  /// A dart.
  static const IconData dart = IconData(0xe002, fontFamily: fontFamily);

  /// “JS”.
  static const IconData javascript = IconData(0xe003, fontFamily: fontFamily);

  /// “TS”.
  static const IconData typescript = IconData(0xe004, fontFamily: fontFamily);

  /// “PY”.
  static const IconData python = IconData(0xe005, fontFamily: fontFamily);

  /// “KT”.
  static const IconData kotlin = IconData(0xe006, fontFamily: fontFamily);

  /// “GO”.
  static const IconData go = IconData(0xe007, fontFamily: fontFamily);

  /// “RS”.
  static const IconData rust = IconData(0xe008, fontFamily: fontFamily);

  /// “C”: C and C++, sources and headers.
  static const IconData cFamily = IconData(0xe009, fontFamily: fontFamily);

  /// A cup.
  static const IconData java = IconData(0xe00a, fontFamily: fontFamily);

  /// Braces.
  static const IconData json = IconData(0xe00b, fontFamily: fontFamily);

  /// An indented list.
  static const IconData yaml = IconData(0xe00c, fontFamily: fontFamily);

  /// “M↓”.
  static const IconData markdown = IconData(0xe00d, fontFamily: fontFamily);

  /// `</>`: HTML and XML.
  static const IconData markup = IconData(0xe00e, fontFamily: fontFamily);

  /// `#`: CSS and its dialects.
  static const IconData css = IconData(0xe00f, fontFamily: fontFamily);

  /// A prompt: shell scripts and their startup files.
  static const IconData shell = IconData(0xe010, fontFamily: fontFamily);

  /// Sliders: TOML, INI, properties and `.env` files.
  static const IconData config = IconData(0xe011, fontFamily: fontFamily);

  /// A picture.
  static const IconData image = IconData(0xe012, fontFamily: fontFamily);

  /// A padlock: package managers' lock files.
  static const IconData lock = IconData(0xe013, fontFamily: fontFamily);

  /// A branch: Git's own files.
  static const IconData git = IconData(0xe014, fontFamily: fontFamily);

  /// Every glyph with its name, in drawing order: the component gallery
  /// shows them all, so the goldens cover each one.
  static const Map<String, IconData> all = {
    'file': file,
    'text': text,
    'dart': dart,
    'javascript': javascript,
    'typescript': typescript,
    'python': python,
    'kotlin': kotlin,
    'go': go,
    'rust': rust,
    'cFamily': cFamily,
    'java': java,
    'json': json,
    'yaml': yaml,
    'markdown': markdown,
    'markup': markup,
    'css': css,
    'shell': shell,
    'config': config,
    'image': image,
    'lock': lock,
    'git': git,
  };

  /// Whole names that decide the glyph before any extension does, compared
  /// in lower case.
  static const Map<String, IconData> _byName = {
    '.gitignore': git,
    '.gitattributes': git,
    '.gitmodules': git,
    '.gitkeep': git,
    '.bashrc': shell,
    '.bash_profile': shell,
    '.profile': shell,
    '.zshrc': shell,
    '.zprofile': shell,
    '.editorconfig': config,
    '.npmrc': config,
    '.nvmrc': config,
    // The rc files that language detection reads as JSON
    // (core/editor/languages.dart).
    '.babelrc': json,
    '.eslintrc': json,
    '.jshintrc': json,
    '.prettierrc': json,
    '.swcrc': json,
    'license': text,
    'licence': text,
    'readme': text,
    'changelog': text,
  };

  static const Map<String, IconData> _byExtension = {
    'dart': dart,
    'js': javascript,
    'mjs': javascript,
    'cjs': javascript,
    'jsx': javascript,
    'ts': typescript,
    'mts': typescript,
    'cts': typescript,
    'tsx': typescript,
    'py': python,
    'pyw': python,
    'pyi': python,
    'kt': kotlin,
    'kts': kotlin,
    'go': go,
    'rs': rust,
    'c': cFamily,
    'h': cFamily,
    'cc': cFamily,
    'cpp': cFamily,
    'cxx': cFamily,
    'hh': cFamily,
    'hpp': cFamily,
    'hxx': cFamily,
    'java': java,
    'json': json,
    'jsonc': json,
    'json5': json,
    'webmanifest': json,
    'yaml': yaml,
    'yml': yaml,
    'md': markdown,
    'markdown': markdown,
    'mdx': markdown,
    'html': markup,
    'htm': markup,
    'xhtml': markup,
    'xml': markup,
    'plist': markup,
    'css': css,
    'scss': css,
    'sass': css,
    'less': css,
    'sh': shell,
    'bash': shell,
    'zsh': shell,
    'fish': shell,
    'toml': config,
    'ini': config,
    'cfg': config,
    'conf': config,
    'properties': config,
    'env': config,
    'txt': text,
    'text': text,
    'log': text,
    'png': image,
    'jpg': image,
    'jpeg': image,
    'gif': image,
    'webp': image,
    'svg': image,
    'ico': image,
    'bmp': image,
    'avif': image,
    'heic': image,
    'lock': lock,
  };

  /// The glyph for a file called [name] (a name, not a path).
  ///
  /// A few whole names come first (`.gitignore`, `.bashrc`, `LICENSE`),
  /// then `.env` and its variants (`.env.local`), then the extension after
  /// the last dot, in any case. Anything else is a generic [file].
  static IconData forName(String name) {
    final lower = name.toLowerCase();
    final byName = _byName[lower];
    if (byName != null) return byName;
    if (lower == '.env' || lower.startsWith('.env.')) return config;
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return file;
    return _byExtension[lower.substring(dot + 1)] ?? file;
  }
}
