import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/fakes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FakeFileService', () {
    late FakeFileService files;

    setUp(() async {
      files = FakeFileService();
      await files.openDemoWorkspace();
    });

    test('lists root with directories first, dotfiles flagged', () async {
      final result = await files.listDirectory('');
      final entries = result.orThrow;
      expect(entries.first.isDirectory, isTrue);
      expect(entries.first.name, 'src');
      final gitignore = entries.firstWhere((e) => e.name == '.gitignore');
      expect(gitignore.hidden, isTrue);
      expect(entries.any((e) => e.name == 'main.js'), isTrue);
    });

    test('lists nested directory', () async {
      final result = await files.listDirectory('src');
      final names = result.orThrow.map((e) => e.name).toList();
      expect(names, containsAll(['greeting.dart', 'notes.txt']));
    });

    test('reads and writes text', () async {
      final content = (await files.readTextFile('main.js')).orThrow;
      expect(content, contains('function main()'));
      await files.writeTextFile('main.js', 'changed');
      expect((await files.readTextFile('main.js')).orThrow, 'changed');
    });

    test('missing file is a typed StorageFailure, not a throw', () async {
      final result = await files.readTextFile('nope.dart');
      expect(result.failureOrNull, isA<StorageFailure>());
    });
  });

  group('FakeEditorService', () {
    test('open → dirty → save lifecycle is real state', () async {
      final files = FakeFileService();
      await files.openDemoWorkspace();
      final editor = FakeEditorService(files);

      final doc = (await editor.openDocument('app.py')).orThrow;
      expect(doc.dirty, isFalse);
      expect(doc.language, 'python');

      editor.updateContent('app.py', 'print("edited")\n');
      expect(editor.document('app.py')!.dirty, isTrue);

      final saved = await editor.saveDocument('app.py');
      expect(saved.isOk, isTrue);
      expect(editor.document('app.py')!.dirty, isFalse);
      // The edited text is what reached the file, not the original.
      expect((await files.readTextFile('app.py')).orThrow, 'print("edited")\n');
    });

    test('saving an unopened document fails typed', () async {
      final files = FakeFileService();
      await files.openDemoWorkspace();
      final editor = FakeEditorService(files);
      final result = await editor.saveDocument('ghost.dart');
      expect(result.failureOrNull, isA<StorageFailure>());
    });
  });

  group('honest availability fakes', () {
    test('terminal reports unavailable with a phase-accurate reason', () {
      final terminal = FakeTerminalService();
      expect(terminal.availability, TerminalAvailability.unavailable);
      expect(terminal.unavailableReason, contains('Phases 4–5'));
    });

    test('runtime reports notInstalled', () async {
      final runtime = FakeRuntimeService();
      expect((await runtime.state()).orThrow, RuntimeState.notInstalled);
    });

    test('git summary is a labeled demo branch', () async {
      final git = FakeGitService();
      expect((await git.summary()).orThrow.branch, 'main');
    });

    test('search matches demo filenames', () async {
      final files = FakeFileService();
      await files.openDemoWorkspace();
      final search = FakeSearchService(files);
      final hits = (await search.searchFiles('main')).orThrow;
      expect(hits, ['main.js']);
      expect((await search.searchFiles('')).orThrow, isEmpty);
    });
  });
}
