/// Workspace-relative paths (docs/EDITOR_ARCHITECTURE.md, "Files").
///
/// Every path the app hands to the file service is relative to the
/// workspace root and '/'-separated: no leading slash and no empty, '.' or
/// '..' segments, so a path alone can never leave the workspace. The file
/// service still resolves symbolic links against the root
/// (services/files/local_file_service.dart): this is the first gate.
library;

/// The longest single file or folder name, in UTF-16 code units (ext4
/// allows 255 bytes; most names are ASCII).
const int maxNameLength = 255;

/// The longest workspace-relative path the app accepts.
const int maxPathLength = 1024;

/// Ending of the temporary file a save writes next to its target before
/// renaming it into place (services/files/local_file_service.dart). Such
/// names are reserved and hidden.
const String reservedTempSuffix = '.cf-tmp';

final RegExp _controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

/// Separators of other systems and characters FAT-formatted storage
/// (Phase 3 folders) cannot hold.
final RegExp _forbiddenCharacters = RegExp(r'[\\:*?"<>|]');

/// Why [path] is not a valid workspace-relative path, in words fit for the
/// user; null when it is valid. The empty string is the workspace root and
/// is valid only when [allowRoot] is set (listing the top folder).
String? workspacePathProblem(String path, {bool allowRoot = false}) {
  if (path.isEmpty) {
    return allowRoot ? null : 'Enter a file name.';
  }
  if (path.length > maxPathLength) {
    return 'The path is longer than $maxPathLength characters.';
  }
  if (path.startsWith('/')) {
    return 'Use a path inside the workspace, such as src/app.js.';
  }
  if (path.endsWith('/')) {
    return 'End the path with a file name.';
  }
  for (final segment in path.split('/')) {
    if (segment.isEmpty) {
      return 'The path has an empty folder name.';
    }
    if (segment == '.' || segment == '..') {
      return 'The path cannot contain "." or ".." folders.';
    }
    final problem = nameProblem(segment);
    if (problem != null) {
      return problem;
    }
  }
  return null;
}

/// Why [name] can't name a file, a folder or a project, in words fit for
/// the user; null when it can. One rule for all three (Phase 3 W3), which
/// every segment of a workspace path also follows.
String? nameProblem(String name) {
  if (name.isEmpty) {
    return 'Enter a name.';
  }
  if (name == '.' || name == '..') {
    return 'A name cannot be "." or "..".';
  }
  if (name.contains('/')) {
    return 'A name cannot contain "/".';
  }
  if (name.length > maxNameLength) {
    return 'A name can be at most $maxNameLength characters.';
  }
  if (_controlCharacters.hasMatch(name)) {
    return 'A name cannot contain control characters.';
  }
  if (_forbiddenCharacters.hasMatch(name)) {
    return r'A name cannot contain \ : * ? " < > |';
  }
  if (name.endsWith(reservedTempSuffix)) {
    return 'Names ending in $reservedTempSuffix are reserved for saving.';
  }
  return null;
}

/// True when [path] is a valid workspace-relative file path.
bool isWorkspacePath(String path) => workspacePathProblem(path) == null;

/// The last segment of [path]: 'src/app.js' → 'app.js'.
String pathBaseName(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// The folder holding [path], '' at the top level: 'src/app.js' → 'src'.
String pathParent(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

/// [name] inside [folder] ('' is the workspace root).
String pathJoin(String folder, String name) =>
    folder.isEmpty ? name : '$folder/$name';
