/// Workspace-relative path rules (Phase 2 W4): the first of the two gates
/// that keep every file operation inside the workspace.
library;

import 'package:codeforge/core/files/workspace_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts plain relative paths', () {
    for (final path in [
      'main.js',
      'src/app.py',
      '.gitignore',
      'a b/c d.txt',
      'deep/er/still/file.md',
      'ünïcode/ファイル.ts',
    ]) {
      expect(workspacePathProblem(path), isNull, reason: path);
      expect(isWorkspacePath(path), isTrue, reason: path);
    }
  });

  test('refuses anything that could leave the workspace or is not a file', () {
    for (final path in [
      '',
      '/etc/passwd',
      '../outside.js',
      'src/../../outside.js',
      'src/./app.js',
      'src//app.js',
      'src/',
      'a\\b.js',
      'c:/x.js',
      'what?.js',
      'nul\u0000.js',
      'tab\there.js',
      '.main.js.cf-tmp',
      'x' * 256,
      'a/' * 600,
    ]) {
      expect(workspacePathProblem(path), isNotNull, reason: path);
    }
  });

  test('the root is only valid where it is allowed', () {
    expect(workspacePathProblem(''), isNotNull);
    expect(workspacePathProblem('', allowRoot: true), isNull);
  });

  test('base name, parent and join', () {
    expect(pathBaseName('src/app.js'), 'app.js');
    expect(pathBaseName('main.js'), 'main.js');
    expect(pathParent('src/app.js'), 'src');
    expect(pathParent('main.js'), '');
    expect(pathJoin('', 'main.js'), 'main.js');
    expect(pathJoin('src', 'app.js'), 'src/app.js');
  });
}
