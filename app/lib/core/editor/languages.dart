/// Language detection for the editor (docs/EDITOR_ARCHITECTURE.md): the host
/// decides by file name, and the page highlights what it is told.
library;

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
  'json': 'json',
  'html': 'html',
  'htm': 'html',
  'css': 'css',
  'md': 'markdown',
  'markdown': 'markdown',
};

/// The editor language for [path]; `plaintext` when nothing matches,
/// including names without an extension and dotfiles such as `.gitignore`.
String languageForPath(String path) {
  final name = path.split('/').last.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot <= 0) {
    return 'plaintext';
  }
  return editorLanguageByExtension[name.substring(dot + 1)] ?? 'plaintext';
}
