/// Go to File's index (Phase 3 W4, application/file_index.dart): built top
/// folders first, without `.git` and `node_modules`, stopping at 50,000
/// files and saying so; kept current by the explorer's operations, New File
/// and Save As; dropped when the workspace changes.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/file_index.dart';
import 'package:codeforge/application/file_operations.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/memory_file_service.dart';

final class _World {
  _World(Map<String, String> seed) : files = MemoryFileService(seed: seed) {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        shellStateStoreProvider.overrideWithValue(InMemoryShellStateStore()),
        fileServiceProvider.overrideWithValue(files),
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        ...fakeEditorOverrides((_) {}),
      ],
    );
  }

  final MemoryFileService files;
  late final ProviderContainer container;

  FileIndexController get index => container.read(fileIndexProvider.notifier);

  FileIndexState get state => container.read(fileIndexProvider);

  List<String> get paths => [for (final file in state.files) file.path];

  FileOperations get operations => container.read(fileOperationsProvider);

  Future<void> start() async {
    container.read(shellControllerProvider);
    await container.read(workspaceControllerProvider.notifier).open();
    await container.read(editorHostProvider).start();
  }

  /// Builds the index and waits for it.
  Future<void> build() async {
    container.read(fileIndexProvider);
    index.ensureBuilt();
    await index.settled;
  }

  /// Waits for the index to apply every change asked for.
  Future<void> settle() async {
    // A change asked for after an await in an operation: let it queue.
    await Future<void>.delayed(Duration.zero);
    await index.settled;
  }
}

void main() {
  test('lists every file, top folders first', () async {
    final w = _World({
      'b/deep/z.dart': '',
      'a.txt': '',
      'b/c.dart': '',
      'README.md': '',
    });
    await w.build();
    expect(w.state.status, FileIndexStatus.ready);
    expect(w.state.truncated, isFalse);
    expect(w.paths, ['a.txt', 'README.md', 'b/c.dart', 'b/deep/z.dart']);
  });

  test('skips .git and node_modules at any depth', () async {
    final w = _World({
      '.git/HEAD': '',
      '.gitignore': '',
      'node_modules/x/index.js': '',
      'web/node_modules/y.js': '',
      'web/app.js': '',
      '.github/ci.yml': '',
    });
    await w.build();
    expect(w.paths, ['.gitignore', '.github/ci.yml', 'web/app.js']);
  });

  test('stops at 50,000 files and says so', () async {
    final w = _World({
      for (var i = 0; i <= FileIndexController.maxEntries; i++) 'f/$i.txt': '',
    });
    await w.build();
    expect(w.state.status, FileIndexStatus.ready);
    expect(w.state.files, hasLength(FileIndexController.maxEntries));
    expect(w.state.truncated, isTrue);
  });

  test('exactly 50,000 files is not cut', () async {
    final w = _World({
      for (var i = 0; i < FileIndexController.maxEntries; i++) 'f/$i.txt': '',
    });
    await w.build();
    expect(w.state.files, hasLength(FileIndexController.maxEntries));
    expect(w.state.truncated, isFalse);
  });

  test('an empty workspace has no files', () async {
    final w = _World(const {});
    await w.build();
    expect(w.state.status, FileIndexStatus.ready);
    expect(w.state.files, isEmpty);
  });

  test('builds once, until rebuilt', () async {
    final w = _World({'a.txt': ''});
    await w.build();
    w.files.putText('b.txt', '');
    w.index.ensureBuilt();
    await w.index.settled;
    expect(w.paths, ['a.txt']);
    await w.index.rebuild();
    expect(w.paths, ['a.txt', 'b.txt']);
  });

  group('follows the explorer', () {
    late _World w;

    setUp(() async {
      w = _World({'src/app.js': '', 'src/lib/util.js': '', 'README.md': ''});
      await w.start();
      await w.build();
    });

    test('rename and move', () async {
      expect((await w.operations.rename('src', 'source')).isOk, isTrue);
      await w.settle();
      expect(w.paths, ['README.md', 'source/app.js', 'source/lib/util.js']);

      expect((await w.operations.move('source/lib/util.js', '')).isOk, isTrue);
      await w.settle();
      expect(w.paths, ['README.md', 'source/app.js', 'util.js']);
    });

    test('a move into node_modules leaves the index', () async {
      w.files.putFolder('node_modules');
      expect(
        (await w.operations.move('src/app.js', 'node_modules')).isOk,
        isTrue,
      );
      await w.settle();
      expect(w.paths, ['README.md', 'src/lib/util.js']);
    });

    test('delete', () async {
      expect((await w.operations.delete('src')).isOk, isTrue);
      await w.settle();
      expect(w.paths, ['README.md']);
    });

    test('duplicate a file and a folder', () async {
      expect(
        (await w.operations.duplicate('README.md', isFolder: false)).isOk,
        isTrue,
      );
      expect(
        (await w.operations.duplicate('src', isFolder: true)).isOk,
        isTrue,
      );
      await w.settle();
      expect(w.paths, [
        'README.md',
        'src/app.js',
        'src/lib/util.js',
        'README copy.md',
        'src copy/app.js',
        'src copy/lib/util.js',
      ]);
    });

    test('New File and Save As', () async {
      final documents = w.container.read(documentControllerProvider.notifier);
      expect((await w.operations.createFile('src/new.js')).isOk, isTrue);
      expect((await documents.saveAs('src/new.js', 'other.js')).isOk, isTrue);
      await w.settle();
      expect(w.paths, [
        'README.md',
        'src/app.js',
        'src/lib/util.js',
        'src/new.js',
        'other.js',
      ]);
    });
  });

  test('an index that is not built ignores changes', () async {
    final w = _World({'a.txt': ''});
    await w.start();
    w.container.read(fileIndexProvider);
    expect((await w.operations.delete('a.txt')).isOk, isTrue);
    await w.settle();
    expect(w.state.status, FileIndexStatus.idle);
  });

  test('switching workspaces drops it', () async {
    final w = _World({'a.txt': ''});
    await w.start();
    await w.build();
    expect(w.paths, ['a.txt']);
    await w.container
        .read(shellControllerProvider.notifier)
        .setWorkspace(
          const ProjectLocation(id: 'project-b', name: 'beta', folder: 'beta'),
        );
    expect(w.state.status, FileIndexStatus.idle);
    expect(w.state.files, isEmpty);
  });

  test('a folder that cannot be listed is left out', () async {
    final w = _World({'a.txt': '', 'locked/b.txt': '', 'c/d.txt': ''});
    w.files.failListings['locked'] = const FileFailure(
      'No access.',
      problem: FileProblem.accessLost,
    );
    await w.build();
    expect(w.state.status, FileIndexStatus.ready);
    expect(w.paths, ['a.txt', 'c/d.txt']);
  });

  test('the top folder failing fails the index, and says why', () async {
    final w = _World({'a.txt': ''});
    w.files.failListings[''] = const FileFailure(
      'The folder is gone.',
      problem: FileProblem.folderMissing,
    );
    await w.build();
    expect(w.state.status, FileIndexStatus.failed);
    expect(w.state.failure?.message, 'The folder is gone.');
    expect(w.state.files, isEmpty);
    // Opening Go to File again tries again.
    w.files.failListings.clear();
    await w.build();
    expect(w.state.status, FileIndexStatus.ready);
    expect(w.paths, ['a.txt']);
  });
}
