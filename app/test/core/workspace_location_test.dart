/// Workspace locations (Phase 3 W3): ids that never change, project names
/// checked against the projects there, stored parts read back safely, and
/// the places the recents show and the picker starts at.
library;

import 'dart:math';

import 'package:codeforge/core/files/workspace_location.dart';
import 'package:flutter_test/flutter_test.dart';

const _cfGate =
    'content://com.android.externalstorage.documents/tree/'
    'primary%3ADocuments%2Fcf-gate';

void main() {
  group('ids', () {
    test('a folder id is part of a hash of its URI, never the URI', () {
      final id = folderWorkspaceId(_cfGate);
      expect(id, matches(RegExp(r'^folder-[0-9a-f]{32}$')));
      expect(id, isNot(contains('cf-gate')));
      expect(folderWorkspaceId(_cfGate), id, reason: 'the same every time');
      expect(const FolderLocation(treeUri: _cfGate, name: 'x').id, id);
      // A reconnected folder keeps the id it had.
      expect(
        const FolderLocation(treeUri: _cfGate, name: 'x', id: 'folder-1').id,
        'folder-1',
      );
    });

    test('project ids do not depend on the name', () {
      final random = Random(7);
      final first = newProjectId(random);
      expect(first, matches(RegExp(r'^project-[0-9a-f]{16}$')));
      expect(newProjectId(random), isNot(first));
      expect(newFolderId(random), matches(RegExp(r'^folder-[0-9a-f]{32}$')));
      expect(adoptedProjectId('app'), adoptedProjectId('app'));
      expect(adoptedProjectId('app'), isNot(adoptedProjectId('App')));
      for (final id in [first, adoptedProjectId('app'), 'demo']) {
        expect(isWorkspaceId(id), isTrue, reason: id);
      }
      for (final id in ['', '../x', 'a/b', '-x', 'x' * 65]) {
        expect(isWorkspaceId(id), isFalse, reason: id);
      }
    });

    test('the demo project is a project like the others', () {
      const demo = DemoProjectLocation();
      expect(demo.id, demoWorkspaceId);
      expect(demo.isDemo, isTrue);
      expect(demo.kind, WorkspaceKind.project);
      expect(demo.location, 'demo');
      expect(
        demo,
        const ProjectLocation(
          id: demoWorkspaceId,
          name: demoProjectName,
          folder: demoProjectFolder,
        ),
      );
    });
  });

  test('project names: the name rule, and not taken in any case', () {
    for (final name in ['my-app', 'App 2', 'ünï']) {
      expect(projectNameProblem(name), isNull, reason: name);
    }
    for (final name in [
      '',
      'a/b',
      '.hidden',
      ' lead',
      'trail ',
      'demo',
      'Demo',
      'x.seeding',
      'x.cf-tmp',
    ]) {
      expect(projectNameProblem(name), isNotNull, reason: name);
    }
    expect(projectNameProblem('APP', taken: ['app']), contains('exists'));
    expect(projectNameProblem('app2', taken: ['app']), isNull);
  });

  group('stored parts', () {
    test('make a project or a folder, or nothing', () {
      expect(
        workspaceFromParts(
          kind: 'project',
          id: 'project-1',
          name: 'App',
          location: 'App',
        ),
        const ProjectLocation(id: 'project-1', name: 'App', folder: 'App'),
      );
      expect(
        workspaceFromParts(
          kind: 'folder',
          id: 'folder-1',
          name: 'cf',
          location: _cfGate,
        ),
        const FolderLocation(treeUri: _cfGate, name: 'cf', id: 'folder-1'),
      );
      // A folder whose place was never recorded: it can be reconnected.
      expect(
        workspaceFromParts(
          kind: 'folder',
          id: 'folder-1',
          name: '',
          location: '',
        ),
        const FolderLocation(treeUri: '', name: 'Folder', id: 'folder-1'),
      );
      expect(
        workspaceFromParts(
          kind: 'project',
          id: 'demo',
          name: 'Anything',
          location: 'anywhere',
        ),
        const DemoProjectLocation(),
      );
      for (final (kind, id, location) in [
        ('project', '../x', 'x'),
        ('project', 'project-1', 'a/b'),
        ('project', 'project-1', '..'),
        ('folder', 'folder-1', 'file:///sdcard'),
        ('folder', 'folder-1', 'content://${'x' * 5000}'),
        ('volume', 'v-1', 'x'),
      ]) {
        expect(
          workspaceFromParts(kind: kind, id: id, name: 'n', location: location),
          isNull,
          reason: '$kind $id $location',
        );
      }
    });
  });

  group('places', () {
    test('as the recents show them', () {
      expect(projectDisplayPath('App'), 'CodeForge projects/App');
      expect(
        folderDisplayPath(_cfGate, 'cf-gate'),
        'Internal storage/Documents/cf-gate',
      );
      expect(
        folderDisplayPath(
          'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3A',
          'card',
        ),
        'Storage 1A2B-3C4D',
      );
      expect(
        folderDisplayPath(
          'content://com.android.providers.downloads.documents/tree/downloads',
          'Download',
        ),
        'Downloads/Download',
      );
      expect(
        folderDisplayPath(
          'content://com.google.android.apps.docs.storage/tree/abc',
          'Drive folder',
        ),
        'Google Drive/Drive folder',
      );
      expect(
        folderDisplayPath('content://com.example.cloud/tree/xyz', 'Cloud'),
        'Other storage/Cloud',
      );
      expect(folderDisplayPath('not a uri', 'Plain'), 'Plain');
      expect(
        displayPathOf(const FolderLocation(treeUri: '', name: 'Old')),
        'Old',
      );
    });

    test('the picker starts at the folder itself, as a document', () {
      expect(
        folderPickerStart(_cfGate),
        'content://com.android.externalstorage.documents/document/'
        'primary%3ADocuments%2Fcf-gate',
      );
      expect(folderPickerStart(''), isNull);
      expect(folderPickerStart('content://a/document/b'), isNull);
    });
  });
}
