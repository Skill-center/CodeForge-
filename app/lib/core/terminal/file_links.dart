/// `file:line` links in a terminal's output (Phase 5 W4): what the page
/// sends when one is tapped (`path:line` or `path:line:column`, the page's
/// links.ts), and where it leads in the open workspace. Pure Dart.
library;

import '../files/workspace_path.dart';

/// A file and a line, with a column when the output gave one.
final class FileLink {
  const FileLink({required this.path, required this.line, this.column});

  final String path;
  final int line;
  final int? column;

  @override
  bool operator ==(Object other) =>
      other is FileLink &&
      other.path == path &&
      other.line == line &&
      other.column == column;

  @override
  int get hashCode => Object.hash(path, line, column);

  @override
  String toString() =>
      'FileLink($path:$line${column == null ? '' : ':$column'})';
}

final RegExp _linkText = RegExp(r'^(.+?):(\d{1,9})(?::(\d{1,9}))?$');

/// [text] as the page sends it; null when it is not a link.
FileLink? parseFileLink(String text) {
  final match = _linkText.firstMatch(text.trim());
  if (match == null) {
    return null;
  }
  final line = int.parse(match.group(2)!);
  if (line < 1) {
    return null;
  }
  final column = match.group(3) == null ? null : int.parse(match.group(3)!);
  return FileLink(
    path: match.group(1)!,
    line: line,
    column: column == null || column < 1 ? null : column,
  );
}

/// [path] from a link as a path in the workspace, or null when it leads
/// elsewhere. A relative path is the workspace's (runs start at its top);
/// an absolute one, or a `file://` URL, must lie in one of [roots]: the
/// workspace's folder on the device, or the folder's run copy.
String? workspacePathForLink(String path, {Iterable<String> roots = const []}) {
  var target = path;
  if (target.startsWith('file://')) {
    try {
      target = Uri.decodeFull(target.substring('file://'.length));
    } on ArgumentError {
      return null;
    }
  }
  var relative = target;
  if (target.startsWith('/')) {
    String? inside;
    for (final root in roots) {
      final top = root.endsWith('/')
          ? root.substring(0, root.length - 1)
          : root;
      if (top.isNotEmpty && target.startsWith('$top/')) {
        inside = target.substring(top.length + 1);
        break;
      }
    }
    if (inside == null) {
      return null;
    }
    relative = inside;
  }
  final parts = <String>[];
  for (final part in relative.split('/')) {
    if (part.isEmpty || part == '.') {
      continue;
    }
    if (part == '..') {
      if (parts.isEmpty) {
        return null;
      }
      parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  if (parts.isEmpty) {
    return null;
  }
  final joined = parts.join('/');
  return isWorkspacePath(joined) ? joined : null;
}

/// [roots] with their other spelling: Android reaches an app's files both
/// through `/data/user/0/<package>` and `/data/data/<package>`, and a
/// program may print either.
List<String> withDataAliases(Iterable<String> roots) {
  const user = '/data/user/0/';
  const data = '/data/data/';
  return [
    for (final root in roots) ...[
      root,
      if (root.startsWith(user)) '$data${root.substring(user.length)}',
      if (root.startsWith(data)) '$user${root.substring(data.length)}',
    ],
  ];
}
