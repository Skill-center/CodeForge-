/// Language detection for the editor (docs/EDITOR_ARCHITECTURE.md): the host
/// decides by file name, extension and shebang line, and the page
/// highlights what it is told.
library;

/// The language of text without syntax support: nothing is highlighted.
const String plainTextLanguage = 'plaintext';

/// File extension (lower case) → one of `editorLanguageIds`.
const Map<String, String> editorLanguageByExtension = {
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'jsx': 'jsx',
  'ts': 'typescript',
  'mts': 'typescript',
  'cts': 'typescript',
  'tsx': 'tsx',
  'py': 'python',
  'pyw': 'python',
  'pyi': 'python',
  'json': 'json',
  'webmanifest': 'json',
  'html': 'html',
  'htm': 'html',
  'css': 'css',
  'md': 'markdown',
  'markdown': 'markdown',
  // Explicitly plain: a shebang line does not turn notes into a script.
  'txt': plainTextLanguage,
};

/// Whole file names (lower case) whose extension, if any, says nothing:
/// JSON configuration dotfiles and the like.
const Map<String, String> editorLanguageByFileName = {
  '.babelrc': 'json',
  '.eslintrc': 'json',
  '.jshintrc': 'json',
  '.prettierrc': 'json',
  '.swcrc': 'json',
  'jakefile': 'javascript',
};

/// Shebang interpreter (lower case, version digits removed) → language.
const Map<String, String> editorLanguageByInterpreter = {
  'node': 'javascript',
  'nodejs': 'javascript',
  'bun': 'javascript',
  'deno': 'typescript',
  'ts-node': 'typescript',
  'tsx': 'typescript',
  'python': 'python',
  'pypy': 'python',
};

final RegExp _whitespace = RegExp(r'\s+');
final RegExp _versionSuffix = RegExp(r'[0-9.]+$');

/// The editor language for [path]: by whole file name, then extension, then
/// the shebang in [firstLine] (when given); `plaintext` when nothing
/// matches, including dotfiles such as `.gitignore`.
String languageForPath(String path, {String? firstLine}) {
  final name = path.split('/').last.toLowerCase();
  final byName = editorLanguageByFileName[name];
  if (byName != null) {
    return byName;
  }
  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    final byExtension = editorLanguageByExtension[name.substring(dot + 1)];
    if (byExtension != null) {
      return byExtension;
    }
  }
  if (firstLine != null) {
    final byShebang = languageForShebang(firstLine);
    if (byShebang != null) {
      return byShebang;
    }
  }
  return plainTextLanguage;
}

/// The language a `#!` line names, or null when it names none we know:
/// `#!/usr/bin/env node`, `#!/usr/bin/python3 -u`,
/// `#!/usr/bin/env -S deno run`.
String? languageForShebang(String line) {
  if (!line.startsWith('#!')) {
    return null;
  }
  final words = line.substring(2).trim().split(_whitespace);
  if (words.first.isEmpty) {
    return null;
  }
  var program = words.first.split('/').last;
  if (program == 'env') {
    // Skip env's own options (-S) and VAR=value assignments.
    var index = 1;
    while (index < words.length &&
        (words[index].startsWith('-') || words[index].contains('='))) {
      index++;
    }
    if (index >= words.length) {
      return null;
    }
    program = words[index].split('/').last;
  }
  final interpreter = program.toLowerCase().replaceFirst(_versionSuffix, '');
  return editorLanguageByInterpreter[interpreter];
}
