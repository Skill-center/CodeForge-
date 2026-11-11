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

  test('one name rule for files, folders and projects (Phase 3 W3)', () {
    for (final name in ['main.js', '.gitignore', 'a b', 'ファイル', 'x' * 255]) {
      expect(nameProblem(name), isNull, reason: name);
    }
    for (final name in [
      '',
      '.',
      '..',
      'a/b',
      'x' * 256,
      'tab\there',
      r'back\slash',
      'colon:',
      'star*',
      'q?',
      '"quoted"',
      '<a>',
      'pipe|',
      'save.cf-tmp',
    ]) {
      expect(nameProblem(name), isNotNull, reason: name);
    }
    // Every segment of a path follows it.
    expect(workspacePathProblem('src/pipe|'), nameProblem('pipe|'));
  });

  group('the explorer (Phase 3 W4)', () {
    test('a path inside a folder, and where a move takes it', () {
      expect(isWithin('src/app.js', 'src'), isTrue);
      expect(isWithin('src', 'src'), isTrue);
      expect(isWithin('src2/app.js', 'src'), isFalse);
      expect(isWithin('sr', 'src'), isFalse);
      expect(isWithin('anything', ''), isTrue);

      expect(movedPath('src', 'src', 'lib'), 'lib');
      expect(movedPath('src/a/b.js', 'src', 'lib/src'), 'lib/src/a/b.js');
      expect(movedPath('src2/a.js', 'src', 'lib'), isNull);
      expect(movedPath('main.js', 'src', 'lib'), isNull);
    });

    test('a copy gets a free name, compared without case', () {
      expect(copyName('app.js', {'app.js'}, isFolder: false), 'app copy.js');
      expect(
        copyName('app.js', {'app.js', 'APP COPY.js'}, isFolder: false),
        'app copy 2.js',
      );
      expect(
        copyName('app.js', {
          'app.js',
          'app copy.js',
          'app copy 2.js',
        }, isFolder: false),
        'app copy 3.js',
      );
      expect(copyName('src', {'src'}, isFolder: true), 'src copy');
      expect(copyName('v1.2', {'v1.2'}, isFolder: true), 'v1.2 copy');
      expect(copyName('.env', {'.env'}, isFolder: false), '.env copy');
      expect(copyName('Makefile', {}, isFolder: false), 'Makefile copy');
      final long = '${'x' * 252}.js';
      final copy = copyName(long, {long}, isFolder: false);
      expect(copy.length, maxNameLength);
      expect(copy, endsWith(' copy.js'));
      expect(nameProblem(copy), isNull);
    });
  });
}
