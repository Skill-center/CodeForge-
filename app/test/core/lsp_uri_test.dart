/// The language servers' URIs and globs (Phase 6 W4, gate G4): file URIs
/// encoded as the servers encode them and decoded however they come back,
/// the roots of projects and of folders' copies, and LSP's glob patterns.
library;

import 'package:codeforge/core/lsp/lsp_glob.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/core/lsp/lsp_uri.dart';
import 'package:flutter_test/flutter_test.dart';

const String _files = '/data/data/dev.codeforge.app/files';

void main() {
  group('file URIs', () {
    test('keep the unreserved characters and /, and encode the rest', () {
      expect(fileUriOf('/a/b-c_d.e~f.py'), 'file:///a/b-c_d.e~f.py');
      expect(fileUriOf('/My Project/x#1.py'), 'file:///My%20Project/x%231.py');
      expect(fileUriOf('/p/100%/c:d'), 'file:///p/100%25/c%3Ad');
      expect(fileUriOf('/p/é😀'), 'file:///p/%C3%A9%F0%9F%98%80');
    });

    test('decode whichever way a server encoded them', () {
      expect(pathOfFileUri('file:///My%20Project/a.py'), '/My Project/a.py');
      expect(pathOfFileUri('file:///c%3Ad'), '/c:d');
      expect(pathOfFileUri('file:///c:d'), '/c:d');
      expect(pathOfFileUri('file://localhost/a/b'), '/a/b');
      expect(pathOfFileUri('FILE:///a'), '/a');
      expect(pathOfFileUri('file:///a+b'), '/a+b');
      expect(pathOfFileUri('file:///p/%C3%A9%F0%9F%98%80'), '/p/é😀');
      expect(pathOfFileUri('file:///a/b?query#part'), '/a/b');
    });

    test('anything else names no file', () {
      expect(pathOfFileUri('untitled:Untitled-1'), isNull);
      expect(pathOfFileUri('https://example.com/a'), isNull);
      expect(pathOfFileUri('file://server/share/a'), isNull);
      expect(pathOfFileUri('file:///a%2'), isNull);
      expect(pathOfFileUri('file:///a%zz'), isNull);
      expect(pathOfFileUri('file:///%FF'), isNull);
    });
  });

  group('roots', () {
    test("a project's documents are named under its folder", () {
      final root = LspRoot('$_files/workspaces/demo');
      expect(root.uri, 'file://$_files/workspaces/demo');
      expect(
        root.uriOf('src/main.py'),
        'file://$_files/workspaces/demo/src/main.py',
      );
      expect(root.uriOf(''), root.uri);
      expect(
        root.relativeOf('file://$_files/workspaces/demo/src/main.py'),
        'src/main.py',
      );
      expect(root.relativeOf(root.uri), '');
    });

    test("a folder's copy is a root of its own", () {
      final root = LspRoot('$_files/copies/f3a9');
      expect(root.uriOf('a b.ts'), 'file://$_files/copies/f3a9/a%20b.ts');
      expect(root.relativeOf('file://$_files/copies/f3a9/a%20b.ts'), 'a b.ts');
      // Another copy, or the project beside it, is outside.
      expect(root.relativeOf('file://$_files/copies/f3a90/a.ts'), isNull);
      expect(root.relativeOf('file://$_files/workspaces/demo/a.ts'), isNull);
    });

    test(
      'a trailing slash, dot segments and doubled slashes do not matter',
      () {
        final root = LspRoot('$_files/workspaces/demo/');
        expect(root.path, '$_files/workspaces/demo');
        expect(
          root.relativeOf('file://$_files/workspaces/demo/./src//a.py'),
          'src/a.py',
        );
        expect(
          root.relativeOf('file://$_files/workspaces/demo/src/../b.py'),
          'b.py',
        );
        expect(
          root.relativeOf('file://$_files/workspaces/demo/../other/b.py'),
          isNull,
        );
      },
    );

    test('a URI round-trips through its path, whatever the name', () {
      final root = LspRoot('$_files/workspaces/My Project');
      for (final path in [
        'a.py',
        'dir with space/b.py',
        'ü/😀.ts',
        '100%.js',
      ]) {
        expect(root.relativeOf(root.uriOf(path)), path);
      }
    });

    test('workspaces are named, never by a path', () {
      expect(const LspWorkspace.project('demo').name, 'demo');
      expect(const LspWorkspace.copy('f3a9').name, 'f3a9');
      expect(const LspWorkspace.project('demo').copy, isNull);
      expect(const LspWorkspace.copy('f3a9').project, isNull);
      expect(
        const LspWorkspace.project('demo'),
        const LspWorkspace.project('demo'),
      );
      expect(
        const LspWorkspace.project('demo') == const LspWorkspace.copy('demo'),
        isFalse,
      );
    });
  });

  group('globs', () {
    bool matches(String glob, String path) => globToRegExp(glob).hasMatch(path);

    test('* stays in a segment, ** crosses them', () {
      expect(matches('*.ts', 'a.ts'), isTrue);
      expect(matches('*.ts', 'src/a.ts'), isFalse);
      expect(matches('**/*.py', '/data/x/a.py'), isTrue);
      expect(matches('**/*.py', 'a.py'), isTrue);
      expect(matches('**/*.py', 'src/a.pyi'), isFalse);
      expect(matches('src/**/*.ts', 'src/a.ts'), isTrue);
      expect(matches('src/**/*.ts', 'src/x/y/a.ts'), isTrue);
      expect(matches('**', '/any/thing'), isTrue);
      expect(matches('**/node_modules/**', '/p/node_modules/x/y.js'), isTrue);
    });

    test('{a,b}, ?, [a-z] and [!a]', () {
      expect(matches('**/*.{py,pyi}', 'src/a.pyi'), isTrue);
      expect(matches('**/*.{py,pyi}', 'src/a.pyc'), isFalse);
      expect(matches('a?c', 'abc'), isTrue);
      expect(matches('a?c', 'a/c'), isFalse);
      expect(matches('[a-c]x', 'bx'), isTrue);
      expect(matches('[a-c]x', 'dx'), isFalse);
      expect(matches('[!a]b', 'cb'), isTrue);
      expect(matches('[!a]b', 'ab'), isFalse);
    });

    test("what is not a glob's is taken literally", () {
      expect(matches('a.b', 'a.b'), isTrue);
      expect(matches('a.b', 'axb'), isFalse);
      expect(matches('(x)+', '(x)+'), isTrue);
      expect(matches('**/pyrightconfig.json', '/r/pyrightconfig.json'), isTrue);
    });
  });
}
