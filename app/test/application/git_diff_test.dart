/// Showing what changed, in the editor (Phase 7 W5, gate G5): the editor
/// host's `diff.open` and `diff.close` and what a page restart shows
/// again, the documents controller's comparisons and its read-only tab
/// for a commit's file, and which revision each tap compares with
/// (application/git/git_diff_controller.dart). The repository is scripted
/// (test/support/scripted_git_service.dart) and the page is the fake one.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/git/git_controller.dart';
import 'package:codeforge/application/git/git_diff_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/editor/languages.dart';
import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/editor/shadow_document.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/fake_runtime_service.dart';
import '../support/fake_storage_broker.dart';
import '../support/memory_file_service.dart';
import '../support/scripted_git_service.dart';

const Duration _debounce = Duration(milliseconds: 20);

Future<void> _drain() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _settle() async {
  await Future<void>.delayed(_debounce * 3);
  await _drain();
}

GitCommit _commit(String hash, {List<String> parents = const ['b']}) =>
    GitCommit(
      hash: hash * 40,
      parents: [for (final parent in parents) parent * 40],
      authorName: 'Ada',
      authorEmail: 'ada@example.com',
      authoredAt: DateTime.utc(2026, 11, 5, 14, 3),
      subject: 'a commit',
    );

GitFileStatus _file(
  String path, {
  GitChange index = GitChange.unmodified,
  GitChange workTree = GitChange.unmodified,
  String? originalPath,
}) => GitFileStatus(
  path: path,
  kind: GitEntryKind.tracked,
  index: index,
  workTree: workTree,
  originalPath: originalPath,
);

GitStatus _status(List<GitFileStatus> files) => GitStatus(
  branch: const GitBranchState(head: 'main', oid: 'a'),
  files: files,
);

/// One app over a scripted repository, an in-memory workspace and the
/// fake editor page.
final class _World {
  _World({ScriptedGitService? git}) : git = git ?? ScriptedGitService() {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        storageBrokerProvider.overrideWithValue(FakeStorageBroker()),
        shellStateStoreProvider.overrideWithValue(InMemoryShellStateStore()),
        fileServiceProvider.overrideWithValue(files),
        sessionStoreProvider.overrideWithValue(sessions),
        runtimeServiceProvider.overrideWithValue(runtime),
        gitServiceProvider.overrideWithValue(this.git),
        gitSettingsProvider.overrideWithValue(
          const GitSettings(debounce: _debounce),
        ),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final MemoryFileService files = MemoryFileService();
  final MemorySessionStore sessions = MemorySessionStore();
  final ScriptedGitService git;
  final FakeRuntimeService runtime = FakeRuntimeService(
    state: RuntimeState.ready,
  );
  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  FakeEditorSurface get page => pages.last;

  EditorHost get host => container.read(editorHostProvider);

  DocumentController get documents =>
      container.read(documentControllerProvider.notifier);

  DocumentsState get state => container.read(documentControllerProvider);

  GitDiffController get diffs =>
      container.read(gitDiffControllerProvider.notifier);

  OpenDocument doc(String path) => state.documents[path]!;

  /// Every `diff.open` the page was sent, newest last.
  List<Map<String, Object?>> get diffOpens => [
    for (final message in page.received)
      if (message.type == 'diff.open') message.payload,
  ];

  Future<void> start() async {
    container
      ..listen(gitControllerProvider, (previous, next) {})
      ..listen(gitDiffControllerProvider, (previous, next) {})
      ..listen(documentControllerProvider, (previous, next) {});
    await host.start();
    await container.read(runtimeControllerProvider.notifier).refresh();
    await _settle();
  }
}

void main() {
  group('the editor host shows a diff (Phase 7 W5)', () {
    test('diff.open carries the older text, and diff.close ends it', () async {
      final w = _World();
      await w.start();
      await w.host.openDocument(
        docId: 'd1',
        text: 'b\n',
        language: plainTextLanguage,
      );
      await _drain();

      final shown = await w.host.openDiff(
        'd1',
        original: 'a\n',
        mode: EditorDiffMode.inline,
      );
      expect(shown.valueOrNull?.mode, EditorDiffMode.inline);
      expect(shown.valueOrNull?.chunks, 1);
      expect(w.diffOpens.single['original'], 'a\n');
      expect(w.diffOpens.single['mode'], 'inline');
      expect(w.page.diffs['d1']?.original, 'a\n');
      expect(w.host.diffOf('d1')?.mode, EditorDiffMode.inline);

      expect((await w.host.closeDiff('d1')).isOk, isTrue);
      expect(w.page.diffs, isEmpty);
      expect(w.host.diffOf('d1'), isNull);
      // Closing a diff that is not there changes nothing.
      expect((await w.host.closeDiff('d1')).isOk, isTrue);
      expect(w.page.receivedTypes.where((t) => t == 'diff.close').length, 1);
    });

    test('two columns are refused for a document that can be edited', () async {
      final w = _World();
      await w.start();
      await w.host.openDocument(
        docId: 'd1',
        text: 'b\n',
        language: plainTextLanguage,
      );
      await w.host.openDocument(
        docId: 'd2',
        text: 'b\n',
        language: plainTextLanguage,
        readOnly: true,
        activate: false,
      );
      await _drain();

      final editable = await w.host.openDiff(
        'd1',
        original: 'a\n',
        mode: EditorDiffMode.split,
      );
      expect(editable.isOk, isFalse);
      expect(w.diffOpens, isEmpty);

      final readOnly = await w.host.openDiff(
        'd2',
        original: 'a\n',
        mode: EditorDiffMode.split,
      );
      expect(readOnly.valueOrNull?.mode, EditorDiffMode.split);
      // The page shows a two-column diff in place of the editor, so its
      // document is the one on screen.
      expect(w.host.activeDocId, 'd2');
    });

    test('a page that restarts is shown the diff again', () async {
      final w = _World();
      await w.start();
      await w.host.openDocument(
        docId: 'd1',
        text: 'b\n',
        language: plainTextLanguage,
      );
      await w.host.openDiff('d1', original: 'a\n', mode: EditorDiffMode.inline);
      await _drain();
      expect(w.diffOpens.length, 1);

      w.page.restartPage();
      await _drain();
      expect(w.page.documents.keys, ['d1']);
      expect(w.page.diffs['d1']?.original, 'a\n');
      expect(w.diffOpens.length, 2);
    });

    test('the older text is refused past the size a diff compares', () async {
      final w = _World();
      await w.start();
      await w.host.openDocument(
        docId: 'd1',
        text: 'b\n',
        language: plainTextLanguage,
      );
      await _drain();
      final huge = 'x\n' * (maxDiffChars ~/ 2 + 1);
      expect(huge.length > maxDiffChars, isTrue);

      final shown = await w.host.openDiff(
        'd1',
        original: huge,
        mode: EditorDiffMode.inline,
      );
      expect(shown.isOk, isFalse);
      expect(w.diffOpens, isEmpty);
    });
  });

  group('a document and what it is compared with (Phase 7 W5)', () {
    test('a comparison follows the document, and is dropped', () async {
      final w = _World();
      await w.start();
      await w.documents.open('main.js');
      await _drain();
      final docId = w.doc('main.js').docId;

      final shown = await w.documents.showDiff(
        'main.js',
        original: 'console.log("old")\n',
        against: againstStaged,
      );
      expect(shown.isOk, isTrue);
      expect(w.doc('main.js').diff?.against, againstStaged);
      expect(w.doc('main.js').diff?.mode, EditorDiffMode.inline);
      expect(w.doc('main.js').diff?.tooLarge, isFalse);
      expect(w.page.diffs[docId]?.mode, 'inline');

      w.documents.hideDiff('main.js');
      await _drain();
      expect(w.doc('main.js').diff, isNull);
      expect(w.page.diffs, isEmpty);
      // The document itself is untouched by either.
      expect(w.state.openPaths, ['main.js']);
      expect(w.doc('main.js').dirty, isFalse);
    });

    test('too large to compare: the file is open, and says so', () async {
      final w = _World();
      await w.start();
      await w.documents.open('main.js');
      await _drain();

      final shown = await w.documents.showDiff(
        'main.js',
        original: 'x\n' * (maxDiffChars ~/ 2 + 1),
        against: againstStaged,
      );
      expect(shown.isOk, isTrue);
      expect(w.doc('main.js').diff?.tooLarge, isTrue);
      expect(w.doc('main.js').diff?.against, againstStaged);
      // Nothing was asked of the page: the file is simply open.
      expect(w.diffOpens, isEmpty);
      expect(w.state.openPaths, ['main.js']);
    });

    test("a commit's file opens read-only, in a tab of its own", () async {
      final w = _World();
      await w.start();
      await w.documents.open('main.js');
      await _drain();

      final shown = await w.documents.openRevision(
        filePath: 'main.js',
        revision: 'a' * 40,
        label: 'aaaaaaa',
        text: 'console.log(2)\n',
        original: 'console.log(1)\n',
        against: againstParent,
        wide: true,
      );
      expect(shown.isOk, isTrue);
      final key = DocumentRevision.tabKeyFor('main.js', 'a' * 40);
      expect(w.state.openPaths, ['main.js', key]);
      expect(w.state.activePath, key);
      final revision = w.doc(key);
      expect(revision.readOnly, isTrue);
      expect(revision.deletedOnDisk, isFalse);
      expect(revision.name, 'main.js at aaaaaaa');
      expect(revision.diff?.mode, EditorDiffMode.split);
      expect(revision.diff?.chunks, 1);
      expect(w.page.documents[revision.docId]?.readOnly, isTrue);
      expect(w.page.diffs[revision.docId]?.mode, 'split');

      // Opening it again activates the tab it is already in.
      await w.documents.open('main.js');
      await w.documents.openRevision(
        filePath: 'main.js',
        revision: 'a' * 40,
        label: 'aaaaaaa',
        text: 'console.log(2)\n',
        original: 'console.log(1)\n',
        against: againstParent,
        wide: true,
      );
      await _drain();
      expect(w.state.openPaths, ['main.js', key]);
      expect(w.state.activePath, key);

      // It is a commit's text: there is nothing to save, and the session
      // does not reopen it.
      final saved = await w.documents.save(key);
      expect(saved.isOk, isFalse);
      await w.documents.persisted;
      final tabs = (await w.sessions.loadTabs('demo')).valueOrNull!;
      expect(tabs.map((t) => t.path), ['main.js']);
    });

    test('one column where two would not fit', () async {
      final w = _World();
      await w.start();
      await w.documents.openRevision(
        filePath: 'main.js',
        revision: 'a' * 40,
        label: 'aaaaaaa',
        text: 'console.log(2)\n',
        original: 'console.log(1)\n',
        against: againstParent,
        wide: false,
      );
      await _drain();
      final key = DocumentRevision.tabKeyFor('main.js', 'a' * 40);
      expect(w.doc(key).diff?.mode, EditorDiffMode.inline);
      expect(w.diffOpens.single['mode'], 'inline');
    });
  });

  group('which revision a tap compares with (Phase 7 W5)', () {
    test('unstaged changes are against the staged version', () async {
      final git = ScriptedGitService(
        status: _status([_file('main.js', workTree: GitChange.modified)]),
      )..filesAt = {':main.js': 'console.log(0)\n'};
      final w = _World(git: git);
      await w.start();

      final shown = await w.diffs.showChanges(
        _file('main.js', workTree: GitChange.modified),
      );
      await _drain();
      expect(shown.isOk, isTrue);
      expect(git.reads, ['file_at :main.js']);
      expect(w.state.openPaths, ['main.js']);
      expect(w.doc('main.js').diff?.against, againstStaged);
      expect(w.diffOpens.single['original'], 'console.log(0)\n');
    });

    test('staged changes are against the last commit', () async {
      final git = ScriptedGitService(
        status: _status([_file('main.js', index: GitChange.modified)]),
      )..filesAt = {'HEAD:main.js': 'console.log(0)\n'};
      final w = _World(git: git);
      await w.start();

      await w.diffs.showChanges(_file('main.js', index: GitChange.modified));
      await _drain();
      expect(git.reads, ['file_at HEAD:main.js']);
      expect(w.doc('main.js').diff?.against, againstHead);
    });

    test('a renamed file is read at the name it had', () async {
      final git = ScriptedGitService(status: _status(const []))
        ..filesAt = {'HEAD:old.js': 'console.log(0)\n'};
      final w = _World(git: git);
      await w.start();
      w.files.putText('main.js', 'console.log(1)\n');

      await w.diffs.showChanges(
        _file('main.js', index: GitChange.renamed, originalPath: 'old.js'),
      );
      await _drain();
      expect(git.reads, ['file_at HEAD:old.js']);
      expect(w.doc('main.js').diff?.against, againstHead);
    });

    test('a new file is compared with nothing, and read nowhere', () async {
      final git = ScriptedGitService(status: _status(const []));
      final w = _World(git: git);
      await w.start();

      await w.diffs.showChanges(
        const GitFileStatus(path: 'main.js', kind: GitEntryKind.untracked),
      );
      await _drain();
      expect(git.reads, isEmpty);
      expect(w.doc('main.js').diff?.against, againstNothing);
      expect(w.diffOpens.single['original'], '');

      // A file staged as new is in no commit either.
      await w.diffs.showChanges(_file('app.py', index: GitChange.added));
      await _drain();
      expect(git.reads, isEmpty);
      expect(w.doc('app.py').diff?.against, againstNothing);
    });

    test('a deleted file has nothing to show', () async {
      final git = ScriptedGitService(status: _status(const []));
      final w = _World(git: git);
      await w.start();

      final shown = await w.diffs.showChanges(
        _file('main.js', workTree: GitChange.deleted),
      );
      expect(shown.isOk, isFalse);
      expect(git.reads, isEmpty);
      expect(w.state.openPaths, isEmpty);
    });

    test('a comparison that cannot be read leaves the file open', () async {
      final git =
          ScriptedGitService(
              status: _status([_file('main.js', workTree: GitChange.modified)]),
            )
            ..fileAtFailure = const GitFailure(
              'Git is busy with this repository.',
              problem: GitProblem.busy,
              operation: 'file_at',
            );
      final w = _World(git: git);
      await w.start();

      final shown = await w.diffs.showChanges(
        _file('main.js', workTree: GitChange.modified),
      );
      await _drain();
      expect(shown.isOk, isFalse);
      expect(w.state.openPaths, ['main.js']);
      expect(w.doc('main.js').diff, isNull);
      expect(w.container.read(gitDiffControllerProvider).loading, isEmpty);
    });

    test("a commit's file is read at it and at the one before", () async {
      final git = ScriptedGitService(status: _status(const []))
        ..filesAt = {
          '${'a' * 40}:main.js': 'console.log(2)\n',
          '${'a' * 40}^:main.js': 'console.log(1)\n',
        };
      final w = _World(git: git);
      await w.start();

      final shown = await w.diffs.showCommitFile(
        _commit('a'),
        const GitCommitFile(path: 'main.js', change: GitChange.modified),
        wide: true,
      );
      await _drain();
      expect(shown.isOk, isTrue);
      expect(git.reads, [
        'file_at ${'a' * 40}:main.js',
        'file_at ${'a' * 40}^:main.js',
      ]);
      final key = DocumentRevision.tabKeyFor('main.js', 'a' * 40);
      expect(w.doc(key).readOnly, isTrue);
      expect(w.doc(key).diff?.against, againstParent);
      expect(w.diffOpens.single['original'], 'console.log(1)\n');
    });

    test('a root commit has nothing before it', () async {
      final git = ScriptedGitService(status: _status(const []))
        ..filesAt = {'${'a' * 40}:main.js': 'console.log(1)\n'};
      final w = _World(git: git);
      await w.start();

      await w.diffs.showCommitFile(
        _commit('a', parents: const []),
        const GitCommitFile(path: 'main.js', change: GitChange.added),
        wide: false,
      );
      await _drain();
      expect(git.reads, ['file_at ${'a' * 40}:main.js']);
      final key = DocumentRevision.tabKeyFor('main.js', 'a' * 40);
      expect(w.doc(key).diff?.against, againstNothing);
      expect(w.diffOpens.single['original'], '');
    });
  });
}
