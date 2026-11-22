/// The `file:` URIs the language servers name documents by (Phase 6 W4).
///
/// The host tells the client its workspace's folder as the server sees it
/// (absolute, links resolved): a project's `<files>/workspaces/<name>`, or a
/// folder's copy `<files>/copies/<id>` (ADR-0013). Every document's URI is
/// built on that root, so the client and the server name a file alike. URIs
/// are encoded as VS Code's URI library encodes them, which both servers use:
/// every byte of the path's UTF-8 is percent-encoded but the unreserved
/// characters and `/`. URIs coming back are decoded before they are
/// compared, since a server may encode differently (`%3A` or `:`).
library;

import 'dart:convert';

/// The `file://` URI of the absolute [path].
String fileUriOf(String path) {
  final out = StringBuffer('file://');
  for (final byte in utf8.encode(path)) {
    if (_unreserved(byte)) {
      out.writeCharCode(byte);
    } else {
      out
        ..write('%')
        ..write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return out.toString();
}

/// The absolute path a `file:` URI names (local, or `localhost`), or null
/// for any other URI and for one that does not decode.
String? pathOfFileUri(String uri) {
  if (uri.length < 5 || uri.substring(0, 5).toLowerCase() != 'file:') {
    return null;
  }
  var rest = uri.substring(5);
  if (rest.startsWith('//')) {
    rest = rest.substring(2);
    final slash = rest.indexOf('/');
    if (slash < 0) {
      return null;
    }
    final authority = rest.substring(0, slash);
    if (authority.isNotEmpty && authority.toLowerCase() != 'localhost') {
      return null;
    }
    rest = rest.substring(slash);
  }
  final end = rest.indexOf(RegExp('[?#]'));
  if (end >= 0) {
    rest = rest.substring(0, end);
  }
  if (!rest.startsWith('/')) {
    return null;
  }
  return _percentDecoded(rest);
}

/// A workspace's folder as its server sees it, and the URIs of the files in
/// it.
final class LspRoot {
  LspRoot(String path) : this._(_withoutTrailingSlash(path));

  LspRoot._(this.path) : uri = fileUriOf(path);

  /// Absolute, without a trailing `/`.
  final String path;

  /// The folder's own URI: the workspace folder's, and `rootUri`.
  final String uri;

  /// The URI of [relative], a workspace path ('' is the folder itself).
  String uriOf(String relative) =>
      relative.isEmpty ? uri : fileUriOf('$path/$relative');

  /// The workspace path [uri] names, or null when it names nothing in the
  /// workspace (another folder, a library, another scheme).
  String? relativeOf(String uri) {
    final absolute = pathOfFileUri(uri);
    if (absolute == null) {
      return null;
    }
    final normalized = _normalized(absolute);
    if (normalized == null) {
      return null;
    }
    if (normalized == path) {
      return '';
    }
    final prefix = path == '/' ? '/' : '$path/';
    if (!normalized.startsWith(prefix)) {
      return null;
    }
    return normalized.substring(prefix.length);
  }
}

bool _unreserved(int byte) =>
    (byte >= 0x41 && byte <= 0x5A) || // A-Z
    (byte >= 0x61 && byte <= 0x7A) || // a-z
    (byte >= 0x30 && byte <= 0x39) || // 0-9
    byte == 0x2D || // -
    byte == 0x2E || // .
    byte == 0x5F || // _
    byte == 0x7E || // ~
    byte == 0x2F; // /

/// [text] with its `%XX` escapes decoded as UTF-8; null when an escape is
/// broken or the bytes are not UTF-8. A `+` stays a `+`.
String? _percentDecoded(String text) {
  if (!text.contains('%')) {
    return text;
  }
  final bytes = <int>[];
  var at = 0;
  while (at < text.length) {
    final percent = text.indexOf('%', at);
    if (percent < 0) {
      bytes.addAll(utf8.encode(text.substring(at)));
      break;
    }
    bytes.addAll(utf8.encode(text.substring(at, percent)));
    if (percent + 2 >= text.length) {
      return null;
    }
    final hex = text.substring(percent + 1, percent + 3);
    if (!_hexPair.hasMatch(hex)) {
      return null;
    }
    bytes.add(int.parse(hex, radix: 16));
    at = percent + 3;
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

final RegExp _hexPair = RegExp(r'^[0-9A-Fa-f]{2}$');

/// [path] with `.` and `..` resolved and repeated slashes folded; null when
/// it climbs above `/`.
String? _normalized(String path) {
  final parts = <String>[];
  for (final part in path.split('/')) {
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
  return '/${parts.join('/')}';
}

String _withoutTrailingSlash(String path) {
  var trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}
