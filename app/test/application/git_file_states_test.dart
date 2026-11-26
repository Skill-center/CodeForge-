/// What the explorer colours its rows by (Phase 7 W4): a file takes its
/// own state, a folder the worst of the files under it, a rename shows at
/// both ends, and an ignored or unchanged file has no state at all.
library;

import 'package:codeforge/application/git/git_file_states.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:flutter_test/flutter_test.dart';

GitFileStatus _tracked(
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

void main() {
  test('a file takes its own state, the work tree before the index', () {
    final states = GitFileStates.of(
      GitStatus(
        branch: const GitBranchState(head: 'main', oid: 'a'),
        files: [
          _tracked('a.txt', workTree: GitChange.modified),
          _tracked('b.txt', index: GitChange.added),
          _tracked('c.txt', workTree: GitChange.deleted),
          // Staged as added, changed again since: the work tree wins.
          _tracked(
            'd.txt',
            index: GitChange.added,
            workTree: GitChange.modified,
          ),
          const GitFileStatus(path: 'new.txt', kind: GitEntryKind.untracked),
          const GitFileStatus(path: 'out.txt', kind: GitEntryKind.ignored),
          _tracked('same.txt'),
          const GitFileStatus(
            path: 'both.txt',
            kind: GitEntryKind.conflicted,
            conflict: GitConflict.bothModified,
          ),
        ],
      ),
    );
    expect(states.stateOf('a.txt'), GitFileState.modified);
    expect(states.stateOf('b.txt'), GitFileState.added);
    expect(states.stateOf('c.txt'), GitFileState.deleted);
    expect(states.stateOf('d.txt'), GitFileState.modified);
    expect(states.stateOf('new.txt'), GitFileState.untracked);
    expect(states.stateOf('out.txt'), isNull);
    expect(states.stateOf('same.txt'), isNull);
    expect(states.stateOf('both.txt'), GitFileState.conflicted);
    expect(states.stateOf('nothing.txt'), isNull);
    expect(states.isEmpty, isFalse);
    expect(GitFileStates.none.isEmpty, isTrue);
    expect(GitFileStates.none.stateOf('a.txt'), isNull);
  });

  test('a folder takes the worst state under it, at every depth', () {
    final states = GitFileStates.of(
      GitStatus(
        branch: const GitBranchState(head: 'main', oid: 'a'),
        files: [
          const GitFileStatus(
            path: 'src/new.txt',
            kind: GitEntryKind.untracked,
          ),
          _tracked('src/deep/a.txt', workTree: GitChange.modified),
          _tracked('docs/readme.md', workTree: GitChange.modified),
          const GitFileStatus(
            path: 'src/deep/both.txt',
            kind: GitEntryKind.conflicted,
            conflict: GitConflict.bothAdded,
          ),
        ],
      ),
    );
    expect(
      states.stateOf('src', isDirectory: true),
      GitFileState.conflicted,
      reason: 'a conflict under it is the worst there is',
    );
    expect(states.stateOf('src/deep', isDirectory: true),
        GitFileState.conflicted);
    expect(states.stateOf('docs', isDirectory: true), GitFileState.modified);
    expect(states.stateOf('src'), isNull, reason: 'as a file it is nothing');
    expect(states.stateOf('other', isDirectory: true), isNull);
  });

  test('a rename shows where the file was and where it is', () {
    final states = GitFileStates.of(
      GitStatus(
        branch: const GitBranchState(head: 'main', oid: 'a'),
        files: [
          _tracked(
            'lib/new_name.dart',
            index: GitChange.renamed,
            originalPath: 'lib/old_name.dart',
          ),
        ],
      ),
    );
    expect(states.stateOf('lib/new_name.dart'), GitFileState.renamed);
    expect(states.stateOf('lib/old_name.dart'), GitFileState.renamed);
    expect(states.stateOf('lib', isDirectory: true), GitFileState.renamed);
  });

  test('the states are ordered worst first, with a letter and a word', () {
    expect(GitFileState.values.first, GitFileState.conflicted);
    expect(
      GitFileState.conflicted.worseThan(GitFileState.untracked),
      isTrue,
    );
    expect(GitFileState.untracked.worseThan(GitFileState.deleted), isFalse);
    expect(
      GitFileState.values.map((s) => s.letter).toList(),
      ['!', 'D', 'M', 'R', 'A', 'U'],
    );
    for (final state in GitFileState.values) {
      expect(state.word, isNotEmpty);
    }
  });
}
