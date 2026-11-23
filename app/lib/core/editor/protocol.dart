/// Editor bridge protocol, version 1: the Dart mirror of
/// editor/src/protocol/ (types.ts and validate.ts).
///
/// Both sides validate every message against the same rules, and the shared
/// fixtures in editor/test/fixtures/protocol/ prove they agree: the page runs
/// them in vitest, the app in test/core/editor_protocol_test.dart. A rule
/// changed on one side must change on the other, with a fixture.
///
/// - Every message is an envelope `{"v": 1, "id", "type", "payload"}`.
///   Unknown versions, types or fields are rejected: both sides ship in the
///   same APK, so an unknown field is a bug, not a newer peer.
/// - Text uses "\n" line breaks only; positions are UTF-16 code units, as in
///   Dart and JavaScript strings.
/// - Edits travel as CodeMirror change-set JSON (see change_set.dart).
library;

import 'dart:convert';

/// Version carried in every envelope (`v`).
const int protocolVersion = 1;

/// Upper bound for one serialized message, in UTF-16 code units. Only
/// whole-document messages (open, replace, snapshot) come near it; the
/// largest supported file is 10 MB.
const int maxMessageChars = 32 * 1024 * 1024;

/// Languages the editor page can highlight.
const List<String> editorLanguageIds = [
  'plaintext',
  'javascript',
  'jsx',
  'typescript',
  'tsx',
  'python',
  'json',
  'html',
  'css',
  'markdown',
];

/// Commands the host can run in the editor (toolbar keys, palette entries).
const List<String> editorCommands = [
  'undo',
  'redo',
  'indentMore',
  'indentLess',
  'insertIndent',
  'selectAll',
  'cursorCharLeft',
  'cursorCharRight',
  'cursorLineUp',
  'cursorLineDown',
  'cursorLineStart',
  'cursorLineEnd',
  'toggleComment',
  'selectNextOccurrence',
  'openSearch',
  'closeSearch',
  'findNext',
  'findPrevious',
  'replaceNext',
  'replaceAll',
  'focus',
  'blur',
  // Language features (Phase 6 W5), at the main cursor: the page asks the
  // host, as F12, F2 and a long press do.
  'goToDefinition',
  'renameSymbol',
  'showHover',
  // The completion list at the cursor, and its selected item taken.
  'startCompletion',
  'acceptCompletion',
];

/// App shortcuts the page forwards: while the WebView has keyboard focus,
/// hardware key events never reach Flutter.
const List<String> appShortcuts = [
  'save',
  'saveAs',
  'palette',
  'closeTab',
  'nextTab',
  'previousTab',
  'newFile',
  'find',
  'replace',
  'gotoLine',
  'goToFile',
  // The Problems sheet (Phase 6 W5).
  'problems',
];

/// Levels of `editor.log` messages.
const List<String> editorLogLevels = ['debug', 'info', 'warn', 'error'];

/// Error codes a `response` may carry.
const List<String> protocolErrorCodes = [
  'bad_json',
  'bad_envelope',
  'unsupported_version',
  'unknown_type',
  'bad_payload',
  'too_large',
  'unknown_doc',
  'doc_exists',
  'no_active_doc',
  'stale',
  'internal',
  // A language request (Phase 6 W5) no server can answer now: none runs for
  // the document, or it is starting, restarting or gave up. Completion falls
  // back to the words of the document.
  'unavailable',
  'timeout',
  'cancelled',
  // The server failed the request, or refused it (nothing to rename there).
  'server_error',
];

// ------------------------------------------------- language features (W5)
//
// Phase 6 W5: the host sends a document's diagnostics (`diag.set`) and a
// rename's edits (`doc.applyEdits`); the page asks for completion, its
// documentation, hover, definition and rename (`lsp.*`), and the host
// answers each through `response`. Positions are offsets into the document
// at the request's version.

/// What `@codemirror/lint` draws.
const List<String> diagnosticSeverities = ['error', 'warning', 'info', 'hint'];

/// LSP's diagnostic tags: faded (unused) and struck through (deprecated).
const List<String> diagnosticTags = ['unnecessary', 'deprecated'];

/// CodeMirror's completion icons, which the host maps LSP's kinds onto.
const List<String> completionKinds = [
  'class',
  'constant',
  'enum',
  'function',
  'interface',
  'keyword',
  'method',
  'namespace',
  'property',
  'text',
  'type',
  'variable',
];

/// LSP's CompletionTriggerKind, by name.
const List<String> completionTriggers = ['invoked', 'character', 'incomplete'];

const List<String> markupKinds = ['markdown', 'plaintext'];

/// The bridge's caps, checked against what the servers gave in W1-W4: the
/// largest completion list had 26 items and the most diagnostics were
/// TypeScript's 199 in the 200-file project (the runtime legs'
/// lsp-report.txt).
///
/// The most diagnostics one document shows.
const int maxDiagnostics = 1000;

/// The most completion items one answer carries, which is also the most the
/// list draws (PHASE_6_PLAN W5: at most 200 shown, trimmed in Dart).
const int maxCompletionItems = 200;

/// The most documents one `doc.applyEdits` changes.
const int maxEditedDocuments = 64;

/// The most edits one document takes in one `doc.applyEdits`.
const int maxDocumentEdits = 10000;

/// The page's requests, each answered by the host through `response`.
const List<String> pageRequestTypes = [
  'lsp.complete',
  'lsp.resolve',
  'lsp.hover',
  'lsp.definition',
  'lsp.prepareRename',
];

/// Which way a message travels; each direction has its own type table.
enum MessageDirection {
  hostToEditor('host-to-editor'),
  editorToHost('editor-to-host');

  const MessageDirection(this.wireName);

  /// The name used by the shared fixtures and in diagnostics.
  final String wireName;

  static MessageDirection? fromWireName(String name) {
    for (final direction in values) {
      if (direction.wireName == name) {
        return direction;
      }
    }
    return null;
  }
}

/// One message that passed validation.
final class BridgeMessage {
  const BridgeMessage({
    required this.id,
    required this.type,
    required this.payload,
  });

  final String id;
  final String type;
  final Map<String, Object?> payload;

  /// The wire form: `{"v": 1, "id": …, "type": …, "payload": …}`.
  String encode() => jsonEncode(<String, Object?>{
    'v': protocolVersion,
    'id': id,
    'type': type,
    'payload': payload,
  });
}

/// Outcome of validating one message.
sealed class ParseResult {
  const ParseResult();
}

final class ParsedMessage extends ParseResult {
  const ParsedMessage(this.message);

  final BridgeMessage message;
}

final class RejectedMessage extends ParseResult {
  const RejectedMessage(this.code, this.reason, {this.id});

  /// One of [protocolErrorCodes].
  final String code;

  /// Names the offending path; never contains document text.
  final String reason;

  /// The envelope id when it could be recovered, so a rejected request can
  /// still be answered.
  final String? id;
}

/// Typed reads from an already validated payload.
extension PayloadReader on Map<String, Object?> {
  String string(String key) => this[key] as String;

  /// JSON integers may decode as double (`7.0`); validation guarantees the
  /// value is integral.
  int integer(String key) => (this[key] as num).toInt();

  double number(String key) => (this[key] as num).toDouble();

  bool flag(String key) => this[key] as bool;

  Map<String, Object?> object(String key) => this[key] as Map<String, Object?>;

  List<Object?> list(String key) => this[key] as List<Object?>;
}

// ------------------------------------------------------------------- rules

/// Returns null when [value] is valid, otherwise a reason naming [path].
typedef _Check = String? Function(Object? value, String path);

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');
final RegExp _docIdPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');
final RegExp _colorPattern = RegExp(r'^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$');

/// JavaScript's Number.MAX_SAFE_INTEGER: the page cannot represent more.
const int _maxSafeInteger = 9007199254740991;

/// What JavaScript's Number.isSafeInteger accepts. JSON decoding gives Dart
/// an int for `7` but a double for `7.0` or `1e3`; JavaScript has one number
/// type, so both must be judged alike.
bool _isSafeInteger(Object? value) {
  if (value is int) {
    return value >= -_maxSafeInteger && value <= _maxSafeInteger;
  }
  if (value is double) {
    return value.isFinite &&
        value == value.truncateToDouble() &&
        value >= -_maxSafeInteger &&
        value <= _maxSafeInteger;
  }
  return false;
}

_Check _str({int? min, int? max, RegExp? pattern, bool lfOnly = false}) {
  return (value, path) {
    if (value is! String) {
      return '$path must be a string';
    }
    if (min != null && value.length < min) {
      return '$path is too short';
    }
    if (max != null && value.length > max) {
      return '$path is too long';
    }
    if (pattern != null && !pattern.hasMatch(value)) {
      return '$path has an invalid format';
    }
    if (lfOnly && value.contains('\r')) {
      return '$path must use \\n line breaks only';
    }
    return null;
  };
}

_Check _int({int? min, int? max}) {
  return (value, path) {
    if (!_isSafeInteger(value)) {
      return '$path must be an integer';
    }
    final number = value as num;
    if (min != null && number < min) {
      return '$path must be ≥ $min';
    }
    if (max != null && number > max) {
      return '$path must be ≤ $max';
    }
    return null;
  };
}

_Check _num({num? min, num? max}) {
  return (value, path) {
    if (value is! num || !value.isFinite) {
      return '$path must be a number';
    }
    if (min != null && value < min) {
      return '$path must be ≥ $min';
    }
    if (max != null && value > max) {
      return '$path must be ≤ $max';
    }
    return null;
  };
}

String? _bool(Object? value, String path) =>
    value is bool ? null : '$path must be a boolean';

_Check _oneOf(List<String> values) {
  return (value, path) => value is String && values.contains(value)
      ? null
      : '$path must be one of: ${values.join(', ')}';
}

String? _anyValue(Object? value, String path) => null;

/// Strict object: every required field present, optional fields typed, no
/// others.
_Check _obj(
  Map<String, _Check> required, [
  Map<String, _Check> optional = const {},
]) {
  return (value, path) {
    if (value is! Map<String, Object?>) {
      return '$path must be an object';
    }
    for (final key in value.keys) {
      if (!required.containsKey(key) && !optional.containsKey(key)) {
        return '$path.$key is not allowed';
      }
    }
    for (final MapEntry(:key, value: check) in required.entries) {
      if (!value.containsKey(key)) {
        return '$path.$key is required';
      }
      final error = check(value[key], '$path.$key');
      if (error != null) {
        return error;
      }
    }
    for (final MapEntry(:key, value: check) in optional.entries) {
      if (value.containsKey(key)) {
        final error = check(value[key], '$path.$key');
        if (error != null) {
          return error;
        }
      }
    }
    return null;
  };
}

_Check _arrayOf(_Check item, {int? max}) {
  return (value, path) {
    if (value is! List<Object?>) {
      return '$path must be an array';
    }
    if (max != null && value.length > max) {
      return '$path has too many items';
    }
    for (var i = 0; i < value.length; i++) {
      final error = item(value[i], '$path[$i]');
      if (error != null) {
        return error;
      }
    }
    return null;
  };
}

final _Check _length = _int(min: 0);

/// CodeMirror change-set JSON (see change_set.dart).
String? _changeSet(Object? value, String path) {
  if (value is! List<Object?>) {
    return '$path must be an array';
  }
  for (var i = 0; i < value.length; i++) {
    final part = value[i];
    final at = '$path[$i]';
    if (part is num) {
      final error = _length(part, at);
      if (error != null) {
        return error;
      }
      continue;
    }
    if (part is! List<Object?> || part.isEmpty) {
      return '$at must be a length or [length, ...lines]';
    }
    final error = _length(part[0], '$at[0]');
    if (error != null) {
      return error;
    }
    for (var j = 1; j < part.length; j++) {
      final line = part[j];
      if (line is! String) {
        return '$at[$j] must be a string';
      }
      if (line.contains('\n') || line.contains('\r')) {
        return '$at[$j] must not contain line breaks';
      }
    }
  }
  return null;
}

final _Check _docId = _str(pattern: _docIdPattern);
final _Check _version = _int(min: 0);
final _Check _text = _str(lfOnly: true);
final _Check _color = _str(pattern: _colorPattern);
final _Check _selection = _obj({'anchor': _length, 'head': _length});

final _Check _palette = _obj({
  'dark': _bool,
  'background': _color,
  'foreground': _color,
  'gutterBackground': _color,
  'gutterForeground': _color,
  'activeLine': _color,
  'selection': _color,
  'cursor': _color,
  'matchingBracket': _color,
  'searchMatch': _color,
  'panelBackground': _color,
  'border': _color,
  'syntax': _obj({
    'keyword': _color,
    'string': _color,
    'number': _color,
    'function': _color,
    'type': _color,
    'comment': _color,
    'operator': _color,
  }),
});

// Language features (Phase 6 W5).
final _Check _requestId = _str(pattern: _idPattern);
final _Check _textEdit = _obj({
  'from': _length,
  'to': _length,
  'insert': _str(lfOnly: true, max: 1000000),
});
final _Check _markup = _obj({
  'kind': _oneOf(markupKinds),
  'value': _str(max: 100000),
});
final _Check _diagnostic = _obj(
  {
    'from': _length,
    'to': _length,
    'severity': _oneOf(diagnosticSeverities),
    'message': _str(max: 4000),
  },
  {
    'source': _str(max: 100),
    'code': _str(max: 100),
    'tags': _arrayOf(_oneOf(diagnosticTags), max: 2),
  },
);
final _Check _documentEdits = _obj({
  'docId': _docId,
  'baseVersion': _version,
  'edits': _arrayOf(_textEdit, max: maxDocumentEdits),
});
final _Check _positionRequest = _obj({
  'docId': _docId,
  'version': _version,
  'pos': _length,
});
final _Check _triggerCharacter = _str(min: 1, max: 1);
final _Check _completionItem = _obj(
  {'label': _str(min: 1, max: 500)},
  {
    'kind': _oneOf(completionKinds),
    'detail': _str(max: 500),
    'sortText': _str(max: 200),
    'filterText': _str(max: 500),
    'edit': _textEdit,
    'insert': _str(lfOnly: true, max: 100000),
    'additionalEdits': _arrayOf(_textEdit, max: 100),
    'resolvable': _bool,
    'deprecated': _bool,
    'preselect': _bool,
  },
);

final Map<String, _Check> _hostToEditor = {
  'editor.configure': _obj({}, {
    'palette': _palette,
    'fontSize': _num(min: 8, max: 40),
    'lineWrapping': _bool,
    'tabSize': _int(min: 1, max: 8),
  }),
  'doc.open': _obj(
    {
      'docId': _docId,
      'text': _text,
      'language': _oneOf(editorLanguageIds),
      'version': _version,
    },
    {
      'readOnly': _bool,
      'selection': _selection,
      'scrollTop': _num(min: 0),
      'activate': _bool,
    },
  ),
  'doc.activate': _obj({'docId': _docId}),
  'doc.close': _obj({'docId': _docId}),
  // With baseVersion (Phase 3 W5) the page refuses (`stale`) unless the
  // document is still at that version with nothing waiting to be sent.
  'doc.replace': _obj(
    {'docId': _docId, 'text': _text, 'version': _version},
    {'baseVersion': _version},
  ),
  'doc.setLanguage': _obj({
    'docId': _docId,
    'language': _oneOf(editorLanguageIds),
  }),
  'doc.flush': _obj({}, {'docId': _docId}),
  'doc.snapshot': _obj({'docId': _docId}),
  'cmd.insert': _obj(
    {'text': _str(min: 1, max: 4096, lfOnly: true)},
    {'cursorOffset': _length},
  ),
  'cmd.exec': _obj({'command': _oneOf(editorCommands)}),
  'cmd.gotoLine': _obj({'line': _int(min: 1)}, {'column': _int(min: 1)}),
  'search.set': _obj(
    {'query': _str(max: 10000)},
    {
      'caseSensitive': _bool,
      'regexp': _bool,
      'wholeWord': _bool,
      'replace': _str(max: 10000),
    },
  ),
  // Phase 6 W5. diag.set: a document's diagnostics at a version, replacing
  // the ones before; the page maps them through its edits since.
  'diag.set': _obj({
    'docId': _docId,
    'version': _version,
    'items': _arrayOf(_diagnostic, max: maxDiagnostics),
  }),
  // A rename's edits to open documents, all or nothing, each document's as
  // one undoable change.
  'doc.applyEdits': _obj({
    'documents': _arrayOf(_documentEdits, max: maxEditedDocuments),
  }),
  // The host's answer to one of the page's requests (lsp.*).
  'response': _responsePayload,
};

final _Check _responseOk = _obj(
  {'re': _str(pattern: _idPattern), 'ok': _bool},
  {'result': _anyValue},
);

final _Check _responseError = _obj({
  're': _str(pattern: _idPattern),
  'ok': _bool,
  'error': _obj({
    'code': _oneOf(protocolErrorCodes),
    'message': _str(max: 2000),
  }),
});

String? _responsePayload(Object? value, String path) {
  if (value is! Map<String, Object?>) {
    return '$path must be an object';
  }
  if (value['ok'] == true) {
    return _responseOk(value, path);
  }
  if (value['ok'] == false) {
    return _responseError(value, path);
  }
  return '$path.ok must be a boolean';
}

final Map<String, _Check> _editorToHost = {
  'editor.ready': _obj({
    'protocol': _int(min: 1),
    'engine': _str(min: 1, max: 64),
    'engineVersion': _str(min: 1, max: 64),
    'languages': _arrayOf(_oneOf(editorLanguageIds), max: 64),
  }),
  'doc.changed': _obj({
    'docId': _docId,
    'baseVersion': _version,
    'version': _version,
    'lengthBefore': _length,
    'lengthAfter': _length,
    'changes': _changeSet,
  }),
  'doc.viewState': _obj({
    'docId': _docId,
    'selection': _selection,
    'scrollTop': _num(min: 0),
  }),
  'editor.history': _obj({'docId': _docId, 'canUndo': _bool, 'canRedo': _bool}),
  'editor.focus': _obj({'focused': _bool}),
  'ime.composition': _obj({'docId': _docId, 'composing': _bool}),
  'app.shortcut': _obj({'shortcut': _oneOf(appShortcuts)}),
  'search.state': _obj({
    'docId': _docId,
    'open': _bool,
    'valid': _bool,
    'matches': _length,
    'current': _length,
    'capped': _bool,
  }),
  'editor.log': _obj({
    'level': _oneOf(editorLogLevels),
    'message': _str(max: 4000),
  }),
  'response': _responsePayload,
  'lsp.complete': _obj(
    {
      'docId': _docId,
      'version': _version,
      'pos': _length,
      'trigger': _oneOf(completionTriggers),
    },
    {'character': _triggerCharacter},
  ),
  'lsp.resolve': _obj({
    'docId': _docId,
    'resultId': _requestId,
    'index': _int(min: 0, max: maxCompletionItems - 1),
  }),
  'lsp.hover': _positionRequest,
  'lsp.definition': _positionRequest,
  'lsp.prepareRename': _positionRequest,
  // The page no longer wants the answer to request `re`; nothing answers it.
  'lsp.cancel': _obj({'re': _requestId}),
};

/// What each of the page's requests answers: the `result` of an ok
/// `response` from the host (editor/src/protocol/validate.ts,
/// PAGE_RESULTS). The page checks the results it gets; the host asserts the
/// ones it sends.
final Map<String, _Check> _pageResults = {
  'lsp.complete': _obj(
    {
      'resultId': _requestId,
      'items': _arrayOf(_completionItem, max: maxCompletionItems),
      'incomplete': _bool,
    },
    {'triggerCharacters': _arrayOf(_triggerCharacter, max: 32)},
  ),
  'lsp.resolve': _obj({}, {
    'detail': _str(max: 2000),
    'documentation': _markup,
    'additionalEdits': _arrayOf(_textEdit, max: 100),
  }),
  'lsp.hover': _obj({}, {
    'contents': _markup,
    'from': _length,
    'to': _length,
  }),
  'lsp.definition': _obj({'found': _length}),
  'lsp.prepareRename': _obj({
    'from': _length,
    'to': _length,
    'placeholder': _str(max: 500),
  }),
};

/// Checks [result], the answer to a page request of [type]: null when it
/// is valid, otherwise a reason naming the bad path.
String? validatePageResult(String type, Object? result) {
  final check = _pageResults[type];
  if (check == null) {
    return 'no result check for $type';
  }
  return check(result, 'result');
}

/// The page requests that have a result check (the contract test holds
/// them equal to [pageRequestTypes] and to the page's PAGE_RESULTS).
Set<String> get pageResultTypes => _pageResults.keys.toSet();

/// The message types accepted travelling in [direction]: the validator's
/// table, which the contract test holds equal to the page's
/// (editor/src/protocol/validate.ts).
Set<String> messageTypes(MessageDirection direction) {
  final table = switch (direction) {
    MessageDirection.hostToEditor => _hostToEditor,
    MessageDirection.editorToHost => _editorToHost,
  };
  return table.keys.toSet();
}

const List<String> _envelopeKeys = ['v', 'id', 'type', 'payload'];

/// Validates an already decoded [value] as a message travelling in
/// [direction]. The checks run in the same order as validate.ts, so both
/// sides report the same error code for the same message.
ParseResult validateMessage(Object? value, MessageDirection direction) {
  if (value is! Map<String, Object?>) {
    return const RejectedMessage('bad_envelope', 'message must be an object');
  }
  // Recover the id early so a rejection can still be answered.
  final rawId = value['id'];
  final id = rawId is String && _idPattern.hasMatch(rawId) ? rawId : null;
  for (final key in value.keys) {
    if (!_envelopeKeys.contains(key)) {
      return RejectedMessage('bad_envelope', '$key is not allowed', id: id);
    }
  }
  if (id == null) {
    return const RejectedMessage(
      'bad_envelope',
      'id must match [A-Za-z0-9_.:-]{1,64}',
    );
  }
  if (value['v'] != protocolVersion) {
    return RejectedMessage(
      'unsupported_version',
      'v must be $protocolVersion',
      id: id,
    );
  }
  final type = value['type'];
  if (type is! String) {
    return RejectedMessage('bad_envelope', 'type must be a string', id: id);
  }
  final table = switch (direction) {
    MessageDirection.hostToEditor => _hostToEditor,
    MessageDirection.editorToHost => _editorToHost,
  };
  final check = table[type];
  if (check == null) {
    return RejectedMessage(
      'unknown_type',
      'unknown ${direction.wireName} type: $type',
      id: id,
    );
  }
  if (!value.containsKey('payload')) {
    return RejectedMessage('bad_envelope', 'payload is required', id: id);
  }
  final payload = value['payload'];
  final error = check(payload, 'payload');
  if (error != null) {
    return RejectedMessage('bad_payload', error, id: id);
  }
  return ParsedMessage(
    BridgeMessage(id: id, type: type, payload: payload as Map<String, Object?>),
  );
}

/// Decodes and validates one serialized message travelling in [direction].
ParseResult parseMessage(String raw, MessageDirection direction) {
  if (raw.length > maxMessageChars) {
    return const RejectedMessage(
      'too_large',
      'message exceeds $maxMessageChars characters',
    );
  }
  final Object? value;
  try {
    value = jsonDecode(raw);
  } on FormatException {
    return const RejectedMessage('bad_json', 'message is not valid JSON');
  }
  return validateMessage(value, direction);
}
