/// Where a workspace lives (Phase 3 W2): the built-in project in the app's
/// own storage, or a folder the user picked from shared storage through
/// Android's folder picker (docs/SECURITY.md §4.1).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The built-in project's id in the session store (DemoWorkspace.id).
const String demoWorkspaceId = 'demo';

sealed class WorkspaceLocation {
  const WorkspaceLocation();

  /// The workspace's id in the session store, which keeps tabs and unsaved
  /// text per id.
  String get id;
}

/// The demo project, in `<filesDir>/workspaces/demo` (Phase 2).
final class DemoProjectLocation extends WorkspaceLocation {
  const DemoProjectLocation();

  @override
  String get id => demoWorkspaceId;

  @override
  bool operator ==(Object other) => other is DemoProjectLocation;

  @override
  int get hashCode => demoWorkspaceId.hashCode;
}

/// A folder from shared storage, reached through the storage broker.
final class FolderLocation extends WorkspaceLocation {
  const FolderLocation({required this.treeUri, required this.name});

  /// The folder grant's tree URI: an opaque token for the broker. It never
  /// reaches the editor page or the logs (docs/SECURITY.md §4.1, S5).
  final String treeUri;

  /// The folder's name as last seen.
  final String name;

  @override
  String get id => folderWorkspaceId(treeUri);

  @override
  bool operator ==(Object other) =>
      other is FolderLocation && other.treeUri == treeUri && other.name == name;

  @override
  int get hashCode => Object.hash(treeUri, name);

  @override
  String toString() => 'FolderLocation($name, $id)';
}

/// The session-store id of the folder granted as [treeUri]: part of a
/// SHA-256 of the URI, so the database never holds the URI itself.
String folderWorkspaceId(String treeUri) =>
    'folder-${sha256.convert(utf8.encode(treeUri)).toString().substring(0, 32)}';
