/// The servers' answers, as the editor draws them (Phase 6 W5,
/// PHASE_6_PLAN W5): completion lists, documentation, hover text,
/// definitions, what a rename would change, and diagnostics, converted from
/// LSP's JSON to the editor protocol's (core/editor/protocol.dart), with
/// positions as offsets into the document the request was about.
///
/// Pure: the language features (application/lsp/lsp_features.dart) ask the
/// server and pass the text the request was made at.
library;

import '../editor/protocol.dart'
    show maxCompletionItems, maxDiagnostics, maxDocumentEdits;
import 'lsp_models.dart';
import 'text_sync.dart';

// ------------------------------------------------------------ completion

/// CodeMirror's icon for LSP's CompletionItemKind, or null for none.
String? completionKindOf(Object? kind) => switch (kind) {
  1 || 15 || 17 => 'text', // Text, Snippet, File
  2 => 'method',
  3 || 23 => 'function', // Function, Event
  4 || 7 || 22 => 'class', // Constructor, Class, Struct
  5 || 10 => 'property', // Field, Property
  6 || 18 => 'variable', // Variable, Reference
  8 => 'interface',
  9 || 19 => 'namespace', // Module, Folder
  11 || 12 || 16 || 20 || 21 => 'constant', // Unit, Value, Color, EnumMember
  13 => 'enum',
  14 || 24 => 'keyword', // Keyword, Operator
  25 => 'type', // TypeParameter
  _ => null,
};

/// A completion answer for the page (`lsp.complete`), and the server's own
/// items behind it, for `completionItem/resolve`.
final class CompletionAnswer {
  const CompletionAnswer({
    required this.items,
    required this.raw,
    required this.incomplete,
    required this.total,
  });

  /// The page's items, at most [maxCompletionItems], in the server's order.
  final List<Map<String, Object?>> items;

  /// The server's items, one for each of [items].
  final List<Map<String, Object?>> raw;

  /// The server said so, or items that match were left out.
  final bool incomplete;

  /// How many items the server gave.
  final int total;
}

/// The identifier being typed before [pos] in [text], '' for none.
String wordBefore(String text, int pos) {
  final end = pos.clamp(0, text.length);
  var start = end;
  while (start > 0 && _isWordUnit(text.codeUnitAt(start - 1))) {
    start -= 1;
  }
  return text.substring(start, end);
}

bool _isWordUnit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) || // 0-9
    (unit >= 0x41 && unit <= 0x5A) || // A-Z
    (unit >= 0x61 && unit <= 0x7A) || // a-z
    unit == 0x5F || // _
    unit == 0x24 || // $
    unit >= 0x80; // letters beyond ASCII, as CodeMirror's \w does not

/// Whether [candidate] can be what the user means by [typed]: its letters in
/// order, case aside, as CodeMirror's matching filters (which the page runs
/// again over what this keeps).
bool fuzzyMatches(String typed, String candidate) {
  if (typed.isEmpty) {
    return true;
  }
  final want = typed.toLowerCase();
  final have = candidate.toLowerCase();
  var at = 0;
  for (var i = 0; i < have.length && at < want.length; i++) {
    if (have.codeUnitAt(i) == want.codeUnitAt(at)) {
      at += 1;
    }
  }
  return at == want.length;
}

/// Converts a server's answer to `textDocument/completion` ([result]: a
/// CompletionList, an array of items, or null) for the page. The items that
/// match the word typed before [pos] are kept, in the server's order
/// (sortText), at most [limit]; when that leaves any out, the answer is
/// incomplete, so the page asks again as the word grows. Edits are offsets
/// into [text], the document the request was made at. [resolvable]: the
/// server resolves items (its `completionProvider.resolveProvider`).
CompletionAnswer completionAnswer(
  Object? result, {
  required String text,
  required int pos,
  required bool resolvable,
  int limit = maxCompletionItems,
}) {
  final List<Object?> items;
  var incomplete = false;
  Map<String, Object?>? defaults;
  if (result is List<Object?>) {
    items = result;
  } else if (result is Map<String, Object?> &&
      result['items'] is List<Object?>) {
    items = result['items']! as List<Object?>;
    incomplete = result['isIncomplete'] == true;
    final itemDefaults = result['itemDefaults'];
    defaults = itemDefaults is Map<String, Object?> ? itemDefaults : null;
  } else {
    items = const [];
  }
  final typed = wordBefore(text, pos);
  final matching = <({int index, String key, Map<String, Object?> item})>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map<String, Object?> || item['label'] is! String) {
      continue;
    }
    final label = item['label']! as String;
    if (label.isEmpty) {
      continue;
    }
    final filter = item['filterText'];
    if (!fuzzyMatches(typed, filter is String ? filter : label)) {
      continue;
    }
    final sort = item['sortText'];
    matching.add((index: i, key: sort is String ? sort : label, item: item));
  }
  matching.sort((a, b) {
    final byKey = a.key.compareTo(b.key);
    return byKey != 0 ? byKey : a.index.compareTo(b.index);
  });
  final index = LineIndex(text);
  final kept = <Map<String, Object?>>[];
  final raw = <Map<String, Object?>>[];
  for (final entry in matching) {
    if (kept.length >= limit) {
      break;
    }
    final converted = _completionItem(
      entry.item,
      index,
      defaults: defaults,
      resolvable: resolvable,
    );
    if (converted != null) {
      kept.add(converted);
      raw.add(entry.item);
    }
  }
  return CompletionAnswer(
    items: kept,
    raw: raw,
    incomplete: incomplete || kept.length < matching.length,
    total: items.length,
  );
}

Map<String, Object?>? _completionItem(
  Map<String, Object?> item,
  LineIndex index, {
  required Map<String, Object?>? defaults,
  required bool resolvable,
}) {
  final label = _clip(item['label']! as String, 500);
  final snippet = item['insertTextFormat'] == 2;
  String plain(String text) =>
      _lf(snippet ? snippetToPlainText(text) : text);
  Map<String, Object?>? edit;
  final textEdit = item['textEdit'];
  final defaultRange = defaults?['editRange'];
  if (textEdit is Map<String, Object?> && textEdit['newText'] is String) {
    final range =
        LspRange.fromJson(textEdit['range']) ??
        LspRange.fromJson(textEdit['insert']);
    if (range != null) {
      edit = _offsets(index, range, plain(textEdit['newText']! as String));
    }
  } else if (defaultRange != null) {
    // LSP 3.17's itemDefaults: the list's range, the item's text.
    final range =
        LspRange.fromJson(defaultRange) ??
        (defaultRange is Map<String, Object?>
            ? LspRange.fromJson(defaultRange['insert'])
            : null);
    final newText = item['textEditText'] ?? item['insertText'] ?? label;
    if (range != null && newText is String) {
      edit = _offsets(index, range, plain(newText));
    }
  }
  if (edit != null && (edit['insert']! as String).length > 100000) {
    return null;
  }
  final insertText = item['insertText'];
  final insert = edit == null && insertText is String
      ? plain(insertText)
      : null;
  if (insert != null && insert.length > 100000) {
    return null;
  }
  final additional = _textEdits(item['additionalTextEdits'], index, max: 100);
  final detail = item['detail'];
  final labelDetails = item['labelDetails'];
  final description = labelDetails is Map<String, Object?>
      ? labelDetails['description']
      : null;
  final sortText = item['sortText'];
  final filterText = item['filterText'];
  final tags = item['tags'];
  final deprecated =
      item['deprecated'] == true || (tags is List<Object?> && tags.contains(1));
  return {
    'label': label,
    'kind': ?completionKindOf(item['kind']),
    if (detail is String && detail.isNotEmpty)
      'detail': _clip(detail, 500)
    else if (description is String && description.isNotEmpty)
      'detail': _clip(description, 500),
    if (sortText is String) 'sortText': _clip(sortText, 200),
    if (filterText is String && filterText.isNotEmpty)
      'filterText': _clip(filterText, 500),
    'edit': ?edit,
    if (insert != null && insert != label) 'insert': insert,
    if (additional.isNotEmpty) 'additionalEdits': additional,
    if (resolvable) 'resolvable': true,
    if (deprecated) 'deprecated': true,
    if (item['preselect'] == true) 'preselect': true,
  };
}

/// What `completionItem/resolve` answered ([result]: the item, completed),
/// for the page (`lsp.resolve`). Edits are offsets into [text], the
/// document the completion was asked in.
Map<String, Object?> resolveAnswer(Object? result, {required String text}) {
  if (result is! Map<String, Object?>) {
    return const {};
  }
  final detail = result['detail'];
  final documentation = markupOf(result['documentation']);
  final additional = _textEdits(
    result['additionalTextEdits'],
    LineIndex(text),
    max: 100,
  );
  return {
    if (detail is String && detail.isNotEmpty) 'detail': _clip(detail, 2000),
    'documentation': ?documentation,
    if (additional.isNotEmpty) 'additionalEdits': additional,
  };
}

/// LSP's snippet syntax as the text it inserts: placeholders keep their
/// default, a choice its first option, tab stops and variables nothing,
/// escapes their character. (The app asks for no snippets; a server may
/// send one anyway.)
String snippetToPlainText(String snippet) => _SnippetReader(snippet).read();

/// Reads LSP's snippet syntax, one character at a time.
final class _SnippetReader {
  _SnippetReader(this.snippet);

  final String snippet;
  int at = 0;

  static final RegExp _digit = RegExp('[0-9]');
  static final RegExp _nameStart = RegExp('[A-Za-z_]');
  static final RegExp _name = RegExp('[A-Za-z0-9_]');

  String read() {
    final out = StringBuffer();
    while (at < snippet.length) {
      final unit = snippet[at];
      if (unit == r'\' && at + 1 < snippet.length) {
        out.write(snippet[at + 1]);
        at += 2;
      } else if (unit == r'$') {
        out.write(_dollar());
      } else {
        out.write(unit);
        at += 1;
      }
    }
    return out.toString();
  }

  /// Up to the `}` that closes a placeholder, or the end: its text.
  String _untilClose() {
    final inner = StringBuffer();
    while (at < snippet.length) {
      final unit = snippet[at];
      if (unit == r'\' && at + 1 < snippet.length) {
        inner.write(snippet[at + 1]);
        at += 2;
      } else if (unit == '}') {
        at += 1;
        return inner.toString();
      } else if (unit == r'$') {
        inner.write(_dollar());
      } else {
        inner.write(unit);
        at += 1;
      }
    }
    return inner.toString();
  }

  /// At a `$`: a tab stop, a placeholder, a choice or a variable.
  String _dollar() {
    at += 1;
    if (at >= snippet.length) {
      return r'$';
    }
    final next = snippet[at];
    if (_digit.hasMatch(next)) {
      while (at < snippet.length && _digit.hasMatch(snippet[at])) {
        at += 1;
      }
      return '';
    }
    if (_nameStart.hasMatch(next)) {
      while (at < snippet.length && _name.hasMatch(snippet[at])) {
        at += 1;
      }
      return '';
    }
    if (next != '{') {
      return r'$';
    }
    at += 1;
    while (at < snippet.length && _name.hasMatch(snippet[at])) {
      at += 1;
    }
    if (at >= snippet.length) {
      return '';
    }
    final separator = snippet[at];
    if (separator == '}') {
      at += 1;
      return '';
    }
    if (separator == ':') {
      at += 1;
      return _untilClose();
    }
    if (separator == '|') {
      at += 1;
      final end = snippet.indexOf('|}', at);
      final choices = end < 0
          ? snippet.substring(at)
          : snippet.substring(at, end);
      at = end < 0 ? snippet.length : end + 2;
      return choices.split(',').first;
    }
    // A transform (`${1/a/b/}`) or something unknown: skipped whole.
    _untilClose();
    return '';
  }
}

// ----------------------------------------------------------------- hover

/// LSP's hover contents or documentation ([contents]: MarkupContent, a
/// MarkedString, or a list of them) as the page's markup; null when there
/// is nothing to show.
Map<String, Object?>? markupOf(Object? contents) {
  String? markdownOf(Object? part) {
    if (part is String) {
      return part;
    }
    if (part is Map<String, Object?>) {
      final value = part['value'];
      final language = part['language'];
      if (value is! String) {
        return null;
      }
      if (language is String) {
        return '```$language\n$value\n```';
      }
      return part['kind'] == 'plaintext' ? _escapeMarkdown(value) : value;
    }
    return null;
  }

  if (contents is Map<String, Object?> &&
      contents['kind'] == 'plaintext' &&
      contents['value'] is String) {
    final value = _lf(contents['value']! as String);
    return value.trim().isEmpty
        ? null
        : {'kind': 'plaintext', 'value': _clip(value, 100000)};
  }
  final parts = contents is List<Object?> ? contents : [contents];
  final markdown = [
    for (final part in parts) ?markdownOf(part),
  ].where((part) => part.trim().isNotEmpty).join('\n\n---\n\n');
  if (markdown.trim().isEmpty) {
    return null;
  }
  return {'kind': 'markdown', 'value': _clip(_lf(markdown), 100000)};
}

/// What `textDocument/hover` answered, for the page (`lsp.hover`): its text,
/// and the range it is about as offsets into [text].
Map<String, Object?> hoverAnswer(Object? result, {required String text}) {
  if (result is! Map<String, Object?>) {
    return const {};
  }
  final contents = markupOf(result['contents']);
  if (contents == null) {
    return const {};
  }
  final range = LspRange.fromJson(result['range']);
  if (range == null) {
    return {'contents': contents};
  }
  final index = LineIndex(text);
  final from = index.offsetAt(range.start);
  final to = index.offsetAt(range.end);
  return {'contents': contents, 'from': from, 'to': to < from ? from : to};
}

// ----------------------------------------------------------- definition

/// A place in a file, as a server names it.
final class LspLocation {
  const LspLocation(this.uri, this.range);

  final String uri;
  final LspRange range;
}

/// The places `textDocument/definition` answered ([result]: a Location, a
/// list of them, a list of LocationLinks, or null), in the server's order.
List<LspLocation> locationsOf(Object? result) {
  LspLocation? one(Object? json) {
    if (json is! Map<String, Object?>) {
      return null;
    }
    final uri = json['uri'] ?? json['targetUri'];
    final range =
        LspRange.fromJson(json['range']) ??
        LspRange.fromJson(json['targetSelectionRange']) ??
        LspRange.fromJson(json['targetRange']);
    if (uri is! String || range == null) {
      return null;
    }
    return LspLocation(uri, range);
  }

  if (result is List<Object?>) {
    return [for (final json in result) ?one(json)];
  }
  final single = one(result);
  return single == null ? const [] : [single];
}

// --------------------------------------------------------------- rename

/// What `textDocument/prepareRename` answered: whether the place can be
/// renamed, the range that would change (null: the word there, LSP's
/// `defaultBehavior`) and the name to start from.
({bool renameable, LspRange? range, String? placeholder}) prepareRenameOf(
  Object? result,
) {
  if (result is! Map<String, Object?>) {
    return (renameable: false, range: null, placeholder: null);
  }
  final asRange = LspRange.fromJson(result);
  if (asRange != null) {
    return (renameable: true, range: asRange, placeholder: null);
  }
  final range = LspRange.fromJson(result['range']);
  final placeholder = result['placeholder'];
  if (range != null) {
    return (
      renameable: true,
      range: range,
      placeholder: placeholder is String ? placeholder : null,
    );
  }
  if (result['defaultBehavior'] == true) {
    return (renameable: true, range: null, placeholder: null);
  }
  return (renameable: false, range: null, placeholder: null);
}

/// The identifier around [pos] in [text], as offsets; null when there is
/// none.
({int from, int to})? wordAt(String text, int pos) {
  final at = pos.clamp(0, text.length);
  var from = at;
  var to = at;
  while (from > 0 && _isWordUnit(text.codeUnitAt(from - 1))) {
    from -= 1;
  }
  while (to < text.length && _isWordUnit(text.codeUnitAt(to))) {
    to += 1;
  }
  return from == to ? null : (from: from, to: to);
}

// ---------------------------------------------------------- diagnostics

/// [diagnostics] as the page draws them (`diag.set`), with offsets into
/// [text], the document they were found in; at most [maxDiagnostics],
/// errors first when there are more.
List<Map<String, Object?>> diagnosticItems(
  List<LspDiagnostic> diagnostics,
  String text,
) {
  final index = LineIndex(text);
  final ordered = diagnostics.length <= maxDiagnostics
      ? diagnostics
      : ([...diagnostics]..sort(
              (a, b) => a.severity.value.compareTo(b.severity.value),
            ))
            .take(maxDiagnostics)
            .toList();
  return [
    for (final d in ordered)
      () {
        final from = index.offsetAt(d.range.start);
        final to = index.offsetAt(d.range.end);
        final source = d.source;
        final code = d.code;
        return <String, Object?>{
          'from': from,
          'to': to < from ? from : to,
          'severity': switch (d.severity) {
            LspSeverity.error => 'error',
            LspSeverity.warning => 'warning',
            LspSeverity.information => 'info',
            LspSeverity.hint => 'hint',
          },
          'message': _clip(d.message, 4000),
          if (source != null && source.isNotEmpty)
            'source': _clip(source, 100),
          if (code != null && code.isNotEmpty) 'code': _clip(code, 100),
          if (d.tags.isNotEmpty) 'tags': [for (final tag in d.tags) tag.name],
        };
      }(),
  ];
}

// ---------------------------------------------------------------- shared

Map<String, Object?> _offsets(LineIndex index, LspRange range, String insert) {
  final from = index.offsetAt(range.start);
  final to = index.offsetAt(range.end);
  return {'from': from, 'to': to < from ? from : to, 'insert': insert};
}

List<Map<String, Object?>> _textEdits(
  Object? json,
  LineIndex index, {
  required int max,
}) {
  if (json is! List<Object?>) {
    return const [];
  }
  final edits = <Map<String, Object?>>[];
  for (final edit in json) {
    if (edit is! Map<String, Object?> || edit['newText'] is! String) {
      continue;
    }
    final range = LspRange.fromJson(edit['range']);
    if (range == null) {
      continue;
    }
    edits.add(_offsets(index, range, _lf(edit['newText']! as String)));
    if (edits.length >= max || edits.length >= maxDocumentEdits) {
      break;
    }
  }
  return edits;
}

/// "\n" line breaks only, as the bridge carries text.
String _lf(String text) =>
    text.contains('\r') ? text.replaceAll('\r\n', '\n').replaceAll('\r', '\n') : text;

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1)}…';

/// Plain text inside Markdown: its special characters escaped.
String _escapeMarkdown(String text) =>
    text.replaceAllMapped(RegExp(r'[\\`*_\[\]#<>]'), (m) => '\\${m[0]}');
