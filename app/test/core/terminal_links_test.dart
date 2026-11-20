/// `file:line` links (Phase 5 W4): what the page sends, and where it leads
/// in the open workspace.
library;

import 'package:codeforge/core/terminal/file_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the page sends path:line, or path:line:column', () {
    expect(
      parseFileLink('src/main.js:12:5'),
      const FileLink(path: 'src/main.js', line: 12, column: 5),
    );
    expect(
      parseFileLink('/w/a b/app.py:3'),
      const FileLink(path: '/w/a b/app.py', line: 3),
    );
    expect(parseFileLink('main.js:0'), isNull);
    expect(parseFileLink('main.js'), isNull);
    expect(parseFileLink('main.js:x'), isNull);
    expect(parseFileLink(':4'), isNull);
  });

  test('a relative path is the workspace’s; .. may not leave it', () {
    expect(workspacePathForLink('main.js'), 'main.js');
    expect(workspacePathForLink('./src/../lib/a.js'), 'lib/a.js');
    expect(workspacePathForLink('../outside.js'), isNull);
    expect(workspacePathForLink('.'), isNull);
  });

  test('an absolute path must lie in the workspace’s folder or copy', () {
    const roots = ['/data/user/0/app/files/workspaces/demo'];
    expect(
      workspacePathForLink(
        '/data/user/0/app/files/workspaces/demo/src/a.js',
        roots: roots,
      ),
      'src/a.js',
    );
    expect(
      workspacePathForLink(
        'file:///data/user/0/app/files/workspaces/demo/my%20app.mjs',
        roots: roots,
      ),
      'my app.mjs',
    );
    expect(
      workspacePathForLink(
        '/data/user/0/app/files/workspaces/demo2/a.js',
        roots: roots,
      ),
      isNull,
    );
    expect(workspacePathForLink('/etc/passwd', roots: roots), isNull);
    expect(workspacePathForLink('/x/a.js'), isNull);
  });

  test('Android’s two spellings of the app’s files both count', () {
    expect(withDataAliases(['/data/user/0/app/files/copies/folder-1']), [
      '/data/user/0/app/files/copies/folder-1',
      '/data/data/app/files/copies/folder-1',
    ]);
    expect(withDataAliases(['/data/data/app/files']), [
      '/data/data/app/files',
      '/data/user/0/app/files',
    ]);
    expect(withDataAliases(['/sdcard/x']), ['/sdcard/x']);
  });
}
