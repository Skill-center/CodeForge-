/// The projects' folders on a real folder (Phase 3 W3, gate G2): created
/// empty or with files, named once in any case, renamed (a change of case
/// too) and deleted without leaving half a project behind, counted, and
/// opened through their file service, which reports a missing folder
/// rather than recreating it. Plain tests: real I/O never completes inside
/// testWidgets' fake async zone.
library;

import 'dart:io';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/files/project_storage.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _fails(FileProblem problem) =>
    isA<FileFailure>().having((f) => f.problem, 'problem', problem);

void main() {
  late Directory temp;
  late String root;
  late LocalProjectStorage storage;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('cf-projects-');
    root = '${temp.path}/workspaces';
    storage = LocalProjectStorage(rootPath: () async => root);
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  List<String> entries() =>
      Directory(root).existsSync()
          ? [
              for (final entity in Directory(root).listSync())
                entity.path.substring(root.length + 1),
            ]
          : const [];

  test('no projects before the first: the folder need not exist', () async {
    expect((await storage.folders()).orThrow, isEmpty);
    expect((await storage.exists('app')).orThrow, isFalse);
  });

  test('a project is created empty or with files, under its name', () async {
    expect((await storage.create('empty')).isOk, isTrue);
    expect(Directory('$root/empty').listSync(), isEmpty);
    expect(
      (await storage.create('sample', seed: DemoWorkspace.files)).isOk,
      isTrue,
    );
    expect(
      File('$root/sample/src/greeting.dart').readAsStringSync(),
      DemoWorkspace.files['src/greeting.dart'],
    );
    expect((await storage.folders()).orThrow, unorderedEquals(['empty', 'sample']));
    expect((await storage.exists('sample')).orThrow, isTrue);
    expect(
      (await storage.countFiles('sample')).orThrow,
      DemoWorkspace.files.length,
    );
    expect((await storage.countFiles('sample', limit: 3)).orThrow, 3);
    expect(entries(), unorderedEquals(['empty', 'sample']), reason: 'no staging left');
  });

  test('a name is taken in any case; a bad name never reaches the disk', () async {
    await storage.create('App');
    expect((await storage.create('app')).failureOrNull, _fails(FileProblem.exists));
    for (final bad in ['', '..', 'a/b', 'x.cf-tmp', 'q?']) {
      expect(
        (await storage.create(bad)).failureOrNull,
        _fails(FileProblem.invalidPath),
        reason: bad,
      );
    }
    expect(entries(), ['App']);
  });

  test('hidden and half-written folders are not projects', () async {
    await storage.create('real');
    Directory('$root/.staging-0123456789ab').createSync(recursive: true);
    Directory('$root/demo$projectStagingSuffix').createSync();
    File('$root/stray.txt').writeAsStringSync('not a project');
    expect((await storage.folders()).orThrow, ['real']);
  });

  test('a rename moves the folder; a change of case goes through a '
      'temporary name; a taken name is refused', () async {
    await storage.create('one', seed: {'a.txt': 'a\n'});
    await storage.create('two');
    expect((await storage.rename('one', 'uno')).isOk, isTrue);
    expect(File('$root/uno/a.txt').readAsStringSync(), 'a\n');
    expect(Directory('$root/one').existsSync(), isFalse);
    expect((await storage.rename('uno', 'Uno')).isOk, isTrue);
    expect(entries(), unorderedEquals(['Uno', 'two']));
    expect(
      (await storage.rename('Uno', 'TWO')).failureOrNull,
      _fails(FileProblem.exists),
    );
    expect(
      (await storage.rename('gone', 'x')).failureOrNull,
      _fails(FileProblem.folderMissing),
    );
    expect((await storage.rename('two', 'two')).isOk, isTrue);
    expect(entries(), unorderedEquals(['Uno', 'two']));
  });

  test('a delete removes everything; nothing there is no failure', () async {
    await storage.create('doomed', seed: {'deep/er/file.txt': 'x'});
    expect((await storage.delete('doomed')).isOk, isTrue);
    expect(entries(), isEmpty);
    expect((await storage.delete('doomed')).isOk, isTrue);
    expect((await storage.delete('../x')).failureOrNull, _fails(FileProblem.invalidPath));
  });

  test("a project's files: its folder, which is reported missing, never "
      'recreated; the demo project is written when it is not there', () async {
    await storage.create('app', seed: {'main.js': 'run();\n'});
    const app = ProjectLocation(id: 'project-1', name: 'app', folder: 'app');
    final files = storage.files(app);
    final opened = (await files.openWorkspace()).orThrow;
    expect(opened.id, 'project-1');
    expect(opened.displayName, 'app');
    expect((await files.readText('main.js')).orThrow.text, 'run();\n');

    const gone = ProjectLocation(id: 'project-2', name: 'gone', folder: 'gone');
    final missing = await storage.files(gone).openWorkspace();
    expect(missing.failureOrNull, _fails(FileProblem.folderMissing));
    expect(missing.failureOrNull!.message, contains('"gone"'));
    expect(Directory('$root/gone').existsSync(), isFalse);

    final demo = storage.files(const DemoProjectLocation());
    expect((await demo.openWorkspace()).orThrow.id, demoWorkspaceId);
    expect(File('$root/demo/main.js').existsSync(), isTrue);
  });
}
