/// Where a workspace lives (Phase 3 W2 and W3): a project, a folder of its
/// own in the app's private storage, or a folder the user picked from
/// shared storage through Android's folder picker (docs/SECURITY.md §4.1).
///
/// The shell envelope names the open workspace this way, the recents keep
/// every workspace opened, and the file services are chosen by it.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'workspace_path.dart';

/// The built-in project's id in the session store (DemoWorkspace.id).
const String demoWorkspaceId = 'demo';

/// The demo project's folder among the projects' folders.
const String demoProjectFolder = 'demo';

/// What the demo project is called.
const String demoProjectName = 'Demo Workspace';

/// Ending of the folder the demo project's files are first written into,
/// before it is renamed into place (services/files/local_file_service.dart).
/// No project may be named so.
const String projectStagingSuffix = '.seeding';

/// The longest folder URI a workspace keeps.
const int maxFolderUriLength = 4096;

/// The two kinds of workspace.
enum WorkspaceKind { project, folder }

sealed class WorkspaceLocation {
  const WorkspaceLocation();

  /// The workspace's id in the session store, which keeps tabs, unsaved
  /// text and the explorer's view per id. It never changes: a renamed
  /// project and a reconnected folder keep theirs.
  String get id;

  /// What the user sees.
  String get name;

  WorkspaceKind get kind;

  /// Where it is: a project's folder name, or a folder's tree URI.
  String get location;
}

/// A project: a folder of its own in the app's private storage,
/// `<filesDir>/workspaces/<folder>` (Phase 3 W3).
final class ProjectLocation extends WorkspaceLocation {
  const ProjectLocation({
    required this.id,
    required this.name,
    required this.folder,
  });

  @override
  final String id;

  @override
  final String name;

  /// The project's folder; for every project but the demo, its name.
  final String folder;

  @override
  WorkspaceKind get kind => WorkspaceKind.project;

  @override
  String get location => folder;

  /// The built-in demo project: written with the sample files whenever it
  /// opens and its folder is not there.
  bool get isDemo => id == demoWorkspaceId;

  @override
  bool operator ==(Object other) =>
      other is ProjectLocation &&
      other.id == id &&
      other.name == name &&
      other.folder == folder;

  @override
  int get hashCode => Object.hash(id, name, folder);

  @override
  String toString() => 'ProjectLocation($id)';
}

/// The demo project, in `<filesDir>/workspaces/demo` (Phase 2).
final class DemoProjectLocation extends ProjectLocation {
  const DemoProjectLocation()
    : super(
        id: demoWorkspaceId,
        name: demoProjectName,
        folder: demoProjectFolder,
      );
}

/// A folder from shared storage, reached through the storage broker.
final class FolderLocation extends WorkspaceLocation {
  /// [id] defaults to [folderWorkspaceId] of [treeUri]; a folder
  /// reconnected at another place keeps the id it had.
  const FolderLocation({required this.treeUri, required this.name, String? id})
    : _id = id;

  /// The folder grant's tree URI: an opaque token for the broker. It never
  /// reaches the editor page or the logs (docs/SECURITY.md §4.1, S5). Empty
  /// for a folder whose place was never recorded (Phase 3 W2 kept only
  /// the open one's): it can only be reconnected.
  final String treeUri;

  @override
  final String name;

  final String? _id;

  @override
  String get id => _id ?? folderWorkspaceId(treeUri);

  @override
  WorkspaceKind get kind => WorkspaceKind.folder;

  @override
  String get location => treeUri;

  @override
  bool operator ==(Object other) =>
      other is FolderLocation &&
      other.id == id &&
      other.treeUri == treeUri &&
      other.name == name;

  @override
  int get hashCode => Object.hash(id, treeUri, name);

  @override
  String toString() => 'FolderLocation($name, $id)';
}

/// The session-store id of the folder granted as [treeUri]: part of a
/// SHA-256 of the URI, so an id never holds the URI itself.
String folderWorkspaceId(String treeUri) =>
    'folder-${sha256.convert(utf8.encode(treeUri)).toString().substring(0, 32)}';

/// The id a project folder found on the device without a record gets: the
/// same every time for the same folder name.
String adoptedProjectId(String folder) =>
    'project-${sha256.convert(utf8.encode('adopted:$folder')).toString().substring(0, 16)}';

/// A new project's id. Random, so it never changes with the project's
/// name.
String newProjectId([Random? random]) => 'project-${_hex(16, random)}';

/// A folder's id when the usual one ([folderWorkspaceId]) already names
/// another folder (that folder was reconnected at this one's old place).
String newFolderId([Random? random]) => 'folder-${_hex(32, random)}';

String _hex(int digits, Random? random) {
  final source = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < digits; i++) {
    buffer.write(source.nextInt(16).toRadixString(16));
  }
  return buffer.toString();
}

final RegExp _workspaceId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');

/// Whether [id] can be a workspace's id: letters, digits, `_` and `-`, at
/// most 64 characters.
bool isWorkspaceId(String id) => _workspaceId.hasMatch(id);

/// Why [name] can't name a new project, or be a project's new name, in
/// words fit for the user; null when it can. Files, folders and projects
/// share [nameProblem]'s rules; a project's name is also its folder's, so
/// it may not start with "." or with or end in a space, and it must differ
/// from every project folder in [taken] even in case alone: two names that
/// differ only in case would be confusing. "demo" is the demo project's.
String? projectNameProblem(String name, {Iterable<String> taken = const []}) {
  final basic = nameProblem(name);
  if (basic != null) {
    return basic;
  }
  if (name.trim() != name) {
    return 'A project name cannot start or end with a space.';
  }
  if (name.startsWith('.')) {
    return 'A project name cannot start with ".".';
  }
  if (name.endsWith(projectStagingSuffix)) {
    return 'Names ending in $projectStagingSuffix are reserved.';
  }
  final lower = name.toLowerCase();
  if (lower == demoProjectFolder ||
      taken.any((folder) => folder.toLowerCase() == lower)) {
    return 'A project named "$name" already exists.';
  }
  return null;
}

/// A workspace from its stored parts (the recents, the shell envelope);
/// null when they don't make one.
WorkspaceLocation? workspaceFromParts({
  required String kind,
  required String id,
  required String name,
  required String location,
}) {
  if (!isWorkspaceId(id) || name.length > maxNameLength) {
    return null;
  }
  switch (kind) {
    case 'project':
      if (id == demoWorkspaceId) {
        return const DemoProjectLocation();
      }
      if (nameProblem(location) != null) {
        return null;
      }
      return ProjectLocation(
        id: id,
        name: name.isEmpty ? location : name,
        folder: location,
      );
    case 'folder':
      if (location.isNotEmpty &&
          (!location.startsWith('content://') ||
              location.length > maxFolderUriLength)) {
        return null;
      }
      return FolderLocation(
        treeUri: location,
        name: name.isEmpty ? 'Folder' : name,
        id: id,
      );
  }
  return null;
}

/// How the recents show a project's place.
String projectDisplayPath(String folder) => 'CodeForge projects/$folder';

final RegExp _treeUri = RegExp(r'^content://([^/]+)/tree/([^/]+)');

/// How the recents show a folder's place, read from its tree URI: the
/// device's shared storage by volume and path, Downloads, Google Drive,
/// or other storage, by the folder's [name].
String folderDisplayPath(String treeUri, String name) {
  final match = _treeUri.firstMatch(treeUri);
  if (match == null) {
    return name;
  }
  final String documentId;
  try {
    documentId = Uri.decodeComponent(match.group(2)!);
  } on Object {
    return name;
  }
  switch (match.group(1)) {
    case 'com.android.externalstorage.documents':
      final colon = documentId.indexOf(':');
      if (colon < 0) {
        return name;
      }
      final volume = documentId.substring(0, colon);
      final path = documentId.substring(colon + 1);
      final root = volume == 'primary' ? 'Internal storage' : 'Storage $volume';
      return path.isEmpty ? root : '$root/$path';
    case 'com.android.providers.downloads.documents':
      return 'Downloads/$name';
    case 'com.google.android.apps.docs.storage':
      return 'Google Drive/$name';
    default:
      return 'Other storage/$name';
  }
}

/// How the recents show [workspace]'s place.
String displayPathOf(WorkspaceLocation workspace) => switch (workspace) {
  ProjectLocation(:final folder) => projectDisplayPath(folder),
  FolderLocation(:final treeUri, :final name) =>
    treeUri.isEmpty ? name : folderDisplayPath(treeUri, name),
};

final RegExp _bareTreeUri = RegExp(r'^content://([^/]+)/tree/([^/]+)$');

/// Where Android's folder picker opens to reconnect the folder granted as
/// [treeUri]: the folder itself, as its provider's document, since the
/// picker's starting place (EXTRA_INITIAL_URI) must be a document; the
/// emulator gate starts the picker the same way. Null when [treeUri] is
/// not a tree URI.
String? folderPickerStart(String treeUri) {
  final match = _bareTreeUri.firstMatch(treeUri);
  return match == null
      ? null
      : 'content://${match.group(1)}/document/${match.group(2)}';
}
