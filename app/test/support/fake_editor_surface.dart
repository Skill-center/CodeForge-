/// A scripted editor page in Dart. It speaks protocol v1 over the
/// EditorSurface interface and validates every host message with the same
/// rules as the real page, so widget and host tests exercise the real
/// EditorHost without a WebView (platform views cannot run under
/// `flutter test`). The real page is covered on the emulator by
/// integration_test/editor_bridge_test.dart.
library;

import 'dart:async';

import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/editor/editor_page.dart';
import 'package:codeforge/services/editor/editor_surface.dart';
import 'package:flutter/widgets.dart';
// Riverpod 3 exports Override from misc.dart, not the main library.
import 'package:flutter_riverpod/misc.dart' show Override;

/// Stands in for the bundled page: no asset reads, no hashing.
const EditorPage fakeEditorPage = EditorPage(
  html: '<!doctype html><title>fake editor</title>',
  sha256: 'fake',
  engineVersion: '0.0.0',
  protocol: protocolVersion,
);

/// Overrides that run the editor host on scripted pages. [onCreate] sees
/// each surface the host creates; [loadPage] replaces the stand-in page.
List<Override> fakeEditorOverrides([
  void Function(FakeEditorSurface surface)? onCreate,
  EditorPageLoader? loadPage,
]) {
  return [
    editorSurfaceFactoryProvider.overrideWithValue(() {
      final surface = FakeEditorSurface();
      onCreate?.call(surface);
      return surface;
    }),
    editorPageLoaderProvider.overrideWithValue(
      loadPage ?? () async => const Ok(fakeEditorPage),
    ),
  ];
}

final class FakeDocument {
  FakeDocument({
    required this.text,
    required this.version,
    required this.language,
    this.anchor,
    this.head,
  });

  String text;
  int version;
  String language;

  /// The page's selection: as `doc.open` gave it, then as
  /// [FakeEditorSurface.moveCursor] moved it.
  int? anchor;
  int? head;
}

final class FakeEditorSurface implements EditorSurface {
  FakeEditorSurface({this.announceReady = true, this.respond = true});

  /// Whether a loaded page announces `editor.ready` (false: a page that
  /// never starts).
  bool announceReady;

  /// Whether requests get responses (false: a hung page).
  bool respond;

  /// While true, requests wait unhandled (a busy page); [release] handles
  /// them in arrival order. They count as [received] when they arrive.
  bool hold = false;
  final List<BridgeMessage> _held = [];

  /// Typed right after the next snapshot is answered: edits racing a save.
  String? typeAfterSnapshot;

  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<EditorSurfaceEvent> _events =
      StreamController<EditorSurfaceEvent>.broadcast();
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// Every valid host message, in arrival order.
  final List<BridgeMessage> received = [];

  /// Error codes of host messages this page rejected.
  final List<String> rejected = [];

  final Map<String, FakeDocument> documents = {};
  String? activeDocId;

  /// The search session as `search.set` last opened it; null while closed.
  Map<String, Object?>? searchSpec;

  /// Commands run with `cmd.exec`, in order.
  final List<String> commands = [];

  /// What `cmd.insert` typed (the symbol toolbar), in order.
  final List<({String text, int? cursorOffset})> inserts = [];

  /// Where `cmd.gotoLine` asked the cursor to go, in order.
  final List<({int line, int? column})> gotoLines = [];
  Map<String, Object?>? configuration;

  /// Documents whose text the host replaced whole (`doc.replace`).
  int replaces = 0;
  String? loadedHtml;
  int loads = 0;
  int reloads = 0;
  bool disposed = false;
  int _nextId = 0;

  List<String> get receivedTypes => [for (final m in received) m.type];

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<EditorSurfaceEvent> get events => _events.stream;

  @override
  Future<void> loadPage(String html) async {
    loads += 1;
    loadedHtml = html;
    _startPage();
  }

  @override
  Future<void> reload() async {
    reloads += 1;
    _startPage();
  }

  /// What a page restart looks like from inside: everything forgotten.
  void restartPage() => _startPage();

  void _startPage() {
    documents.clear();
    activeDocId = null;
    configuration = null;
    searchSpec = null;
    _changed();
    if (announceReady) {
      announce();
    }
  }

  /// Posts `editor.ready`, as a starting page does.
  void announce() => emit('editor.ready', {
    'protocol': protocolVersion,
    'engine': 'fake',
    'engineVersion': '0.0.0',
    'languages': editorLanguageIds,
  });

  @override
  Future<void> deliver(String message) async {
    switch (parseMessage(message, MessageDirection.hostToEditor)) {
      case RejectedMessage(:final code, :final reason, :final id):
        rejected.add(code);
        if (id != null && respond) {
          _error(id, code, reason);
        }
      case ParsedMessage(message: final parsed):
        received.add(parsed);
        if (hold) {
          _held.add(parsed);
        } else if (respond) {
          _handle(parsed);
        }
    }
  }

  /// Ends [hold]: the held requests are handled now, in arrival order.
  void release() {
    hold = false;
    final held = [..._held];
    _held.clear();
    for (final message in held) {
      if (respond) {
        _handle(message);
      }
    }
  }

  void _handle(BridgeMessage message) {
    final id = message.id;
    final payload = message.payload;
    switch (message.type) {
      case 'editor.configure':
        configuration = payload;
        _changed();
        _ok(id);
      case 'doc.open':
        _open(id, payload);
      case 'doc.activate':
        _withDocument(id, payload, (docId, doc) {
          activeDocId = docId;
          _changed();
          _ok(id);
          // Like the real page: an open search session follows the tab.
          if (searchSpec != null) {
            _reportSearch();
          }
        });
      case 'doc.close':
        _withDocument(id, payload, (docId, doc) {
          documents.remove(docId);
          if (activeDocId == docId) {
            activeDocId = null;
          }
          _changed();
          _ok(id);
        });
      case 'doc.replace':
        _withDocument(id, payload, (docId, doc) {
          // Like the real page: a guarded replace (Phase 3 W5) leaves a
          // document that moved on alone. Edits are never held back here,
          // so the version alone tells.
          final base = payload['baseVersion'];
          if (base is int && base != doc.version) {
            _error(
              id,
              'stale',
              'document $docId is at version ${doc.version}, not $base',
            );
            return;
          }
          doc
            ..text = payload.string('text')
            ..version = payload.integer('version');
          replaces += 1;
          _changed();
          _ok(id);
        });
      case 'doc.setLanguage':
        _withDocument(id, payload, (docId, doc) {
          doc.language = payload.string('language');
          _changed();
          _ok(id);
        });
      case 'doc.snapshot':
        _withDocument(id, payload, (docId, doc) {
          _ok(id, {
            'docId': docId,
            'text': doc.text,
            'version': doc.version,
            'selection': {'anchor': 0, 'head': 0},
            // Like the real page: scroll is known for the active one only.
            if (docId == activeDocId) 'scrollTop': 0,
          });
          final racing = typeAfterSnapshot;
          if (racing != null) {
            typeAfterSnapshot = null;
            typeText(racing, docId: docId);
          }
        });
      case 'cmd.insert':
        _insert(id, payload);
      case 'cmd.exec':
        _exec(id, payload.string('command'));
      case 'cmd.gotoLine':
        _gotoLine(id, payload);
      case 'search.set':
        _setSearch(id, payload);
      default:
        // doc.flush: edits are never held back here.
        _ok(id);
    }
  }

  // ---------------------------------------------------------------- search

  /// The real page's counting cap (MAX_COUNTED_MATCHES).
  static const int searchCap = 1000;

  void _setSearch(String id, Map<String, Object?> payload) {
    final docId = activeDocId;
    if (docId == null || !documents.containsKey(docId)) {
      _error(id, 'no_active_doc', 'no document is active');
      return;
    }
    searchSpec = Map.of(payload);
    _ok(id, {'valid': _searchPattern() != null});
    _reportSearch();
  }

  /// The session's query as a Dart pattern; null when it is not usable.
  RegExp? _searchPattern() {
    final spec = searchSpec;
    final query = spec == null ? '' : spec.string('query');
    if (spec == null || query.isEmpty) {
      return null;
    }
    var source = spec['regexp'] == true ? query : RegExp.escape(query);
    if (spec['wholeWord'] == true) {
      source = '\\b(?:$source)\\b';
    }
    try {
      return RegExp(
        source,
        caseSensitive: spec['caseSensitive'] == true,
        multiLine: true,
      );
    } on FormatException {
      return null;
    }
  }

  /// Every non-empty match in [text].
  List<Match> _searchMatches(String text) {
    final pattern = _searchPattern();
    if (pattern == null) {
      return const [];
    }
    return [
      for (final match in pattern.allMatches(text))
        if (match.end > match.start) match,
    ];
  }

  /// Posts `search.state` for the active document, as the page does.
  void _reportSearch() {
    final docId = activeDocId;
    final doc = docId == null ? null : documents[docId];
    if (docId == null || doc == null) {
      return;
    }
    if (searchSpec == null) {
      emit('search.state', {
        'docId': docId,
        'open': false,
        'valid': false,
        'matches': 0,
        'current': 0,
        'capped': false,
      });
      return;
    }
    final all = _searchMatches(doc.text);
    final counted = all.take(searchCap).toList();
    final (from, to) = _selected(doc);
    final current = counted.indexWhere((m) => m.start == from && m.end == to);
    emit('search.state', {
      'docId': docId,
      'open': true,
      'valid': _searchPattern() != null,
      'matches': counted.length,
      'current': current + 1,
      'capped': all.length > searchCap,
    });
  }

  (int, int) _selected(FakeDocument doc) {
    final anchor = doc.anchor ?? 0;
    final head = doc.head ?? anchor;
    return anchor < head ? (anchor, head) : (head, anchor);
  }

  void _exec(String id, String command) {
    commands.add(command);
    switch (command) {
      case 'closeSearch':
        final wasOpen = searchSpec != null;
        searchSpec = null;
        if (wasOpen) {
          _reportSearch();
        }
        _ok(id, {'ran': wasOpen});
      case 'findNext' || 'findPrevious' || 'replaceNext' || 'replaceAll':
        final docId = activeDocId;
        if (docId == null || !documents.containsKey(docId)) {
          _error(id, 'no_active_doc', 'no document is active');
          return;
        }
        _ok(id, {'ran': _searchStep(docId, command)});
      default:
        _ok(id, {'ran': true});
    }
  }

  /// Finds or replaces as CodeMirror's commands do; group references in a
  /// replacement are not expanded here.
  bool _searchStep(String docId, String command) {
    final doc = documents[docId]!;
    final matches = _searchMatches(doc.text);
    final spec = searchSpec;
    if (spec == null || matches.isEmpty) {
      return false;
    }
    final (from, to) = _selected(doc);
    final replacement = (spec['replace'] as String?) ?? '';
    Match nextFrom(List<Match> all, int at) =>
        all.firstWhere((m) => m.start >= at, orElse: () => all.first);
    switch (command) {
      case 'findNext':
        final next = nextFrom(matches, to);
        moveCursor(next.start, head: next.end, docId: docId);
      case 'findPrevious':
        final previous = matches.lastWhere(
          (m) => m.end <= from && !(m.start == from && m.end == to),
          orElse: () => matches.last,
        );
        moveCursor(previous.start, head: previous.end, docId: docId);
      case 'replaceNext':
        final onMatch = matches.any((m) => m.start == from && m.end == to);
        if (!onMatch) {
          final next = nextFrom(matches, to);
          moveCursor(next.start, head: next.end, docId: docId);
          break;
        }
        _change(docId, at: from, delete: to - from, insert: replacement);
        final rest = _searchMatches(doc.text);
        if (rest.isEmpty) {
          moveCursor(from + replacement.length, docId: docId);
        } else {
          final next = nextFrom(rest, from + replacement.length);
          moveCursor(next.start, head: next.end, docId: docId);
        }
      case 'replaceAll':
        final text = doc.text;
        final buffer = StringBuffer();
        var last = 0;
        for (final match in matches) {
          buffer
            ..write(text.substring(last, match.start))
            ..write(replacement);
          last = match.end;
        }
        buffer.write(text.substring(last));
        _change(docId, at: 0, delete: text.length, insert: buffer.toString());
    }
    _reportSearch();
    return true;
  }

  void _gotoLine(String id, Map<String, Object?> payload) {
    final docId = activeDocId;
    final doc = docId == null ? null : documents[docId];
    if (docId == null || doc == null) {
      _error(id, 'no_active_doc', 'no document is active');
      return;
    }
    final line = payload.integer('line');
    final column = payload['column'] == null ? null : payload.integer('column');
    gotoLines.add((line: line, column: column));
    final lines = doc.text.split('\n');
    final target = line > lines.length ? lines.length : line;
    var position = 0;
    for (var i = 0; i < target - 1; i++) {
      position += lines[i].length + 1;
    }
    final wanted = (column ?? 1) - 1;
    final length = lines[target - 1].length;
    position += wanted > length ? length : wanted;
    moveCursor(position, docId: docId);
    _ok(id, {'line': target, 'position': position});
  }

  /// Escape pressed in the editor: the page ends the session itself.
  void pressEscapeInEditor() {
    if (searchSpec != null) {
      searchSpec = null;
      _reportSearch();
    }
  }

  void _open(String id, Map<String, Object?> payload) {
    final docId = payload.string('docId');
    if (documents.containsKey(docId)) {
      _error(id, 'doc_exists', 'document $docId is already open');
      return;
    }
    final selection = payload['selection'];
    documents[docId] = FakeDocument(
      text: payload.string('text'),
      version: payload.integer('version'),
      language: payload.string('language'),
      anchor: selection is Map<String, Object?>
          ? selection['anchor'] as int?
          : null,
      head: selection is Map<String, Object?>
          ? selection['head'] as int?
          : null,
    );
    if (payload['activate'] != false) {
      activeDocId = docId;
    }
    _changed();
    _ok(id);
  }

  void _withDocument(
    String id,
    Map<String, Object?> payload,
    void Function(String docId, FakeDocument doc) action,
  ) {
    final docId = payload.string('docId');
    final doc = documents[docId];
    if (doc == null) {
      _error(id, 'unknown_doc', 'no document $docId');
      return;
    }
    action(docId, doc);
  }

  void _insert(String id, Map<String, Object?> payload) {
    final docId = activeDocId;
    final doc = docId == null ? null : documents[docId];
    if (docId == null || doc == null) {
      _error(id, 'no_active_doc', 'no document is active');
      return;
    }
    final text = payload.string('text');
    final offset = payload['cursorOffset'];
    final cursorOffset = offset is int ? offset : null;
    inserts.add((text: text, cursorOffset: cursorOffset));
    // Replaces the selection, as the page does. The cursor of a freshly
    // opened document sits at its start.
    final anchor = doc.anchor ?? 0;
    final head = doc.head ?? anchor;
    final from = anchor < head ? anchor : head;
    final to = anchor < head ? head : anchor;
    _change(docId, at: from, delete: to - from, insert: text);
    final caret =
        from +
        (cursorOffset == null || cursorOffset > text.length
            ? text.length
            : cursorOffset);
    doc
      ..anchor = caret
      ..head = caret;
    _ok(id, {'inserted': true});
  }

  // ------------------------------------------------------------ test controls

  /// Types [text] at the end of the active document (or [docId]), the way
  /// the page reports a user's typing: one `doc.changed` batch.
  void typeText(String text, {String? docId}) {
    final target = docId ?? activeDocId;
    final doc = target == null ? null : documents[target];
    if (target == null || doc == null) {
      throw StateError('no document to type into');
    }
    _change(target, at: doc.text.length, delete: 0, insert: text);
  }

  /// Deletes the last [count] characters of the active document (or
  /// [docId]), as backspacing reports them.
  void deleteText(int count, {String? docId}) {
    final target = docId ?? activeDocId;
    final doc = target == null ? null : documents[target];
    if (target == null || doc == null || count > doc.text.length) {
      throw StateError('nothing to delete');
    }
    _change(target, at: doc.text.length - count, delete: count, insert: '');
  }

  /// Reports a selection and scroll offset for the active document (or
  /// [docId]), as the page does after the cursor moves (`doc.viewState`).
  void moveCursor(
    int anchor, {
    int? head,
    double scrollTop = 0,
    String? docId,
  }) {
    final target = docId ?? activeDocId;
    if (target == null) {
      throw StateError('no document to move the cursor in');
    }
    documents[target]
      ?..anchor = anchor
      ..head = head ?? anchor;
    emit('doc.viewState', {
      'docId': target,
      'selection': {'anchor': anchor, 'head': head ?? anchor},
      'scrollTop': scrollTop,
    });
  }

  /// Presses an app shortcut while the page has focus (`app.shortcut`).
  void pressShortcut(String shortcut) =>
      emit('app.shortcut', {'shortcut': shortcut});

  /// Posts any string as if the page had sent it, valid or not.
  void emitRaw(String raw) {
    if (!_messages.isClosed) {
      _messages.add(raw);
    }
  }

  /// Posts a well-formed editor → host message.
  void emit(String type, Map<String, Object?> payload) {
    _nextId += 1;
    emitRaw(
      BridgeMessage(id: 'e$_nextId', type: type, payload: payload).encode(),
    );
  }

  void _change(
    String docId, {
    required int at,
    required int delete,
    required String insert,
  }) {
    final doc = documents[docId]!;
    final before = doc.text;
    final tail = before.length - at - delete;
    final changes = <Object?>[
      if (at > 0) at,
      [delete, ...insert.split('\n')],
      if (tail > 0) tail,
    ];
    doc.text = before.replaceRange(at, at + delete, insert);
    final baseVersion = doc.version;
    doc.version += 1;
    emit('doc.changed', {
      'docId': docId,
      'baseVersion': baseVersion,
      'version': doc.version,
      'lengthBefore': before.length,
      'lengthAfter': doc.text.length,
      'changes': changes,
    });
    _changed();
    // The real page recounts an open session as the text changes.
    if (searchSpec != null && docId == activeDocId) {
      _reportSearch();
    }
  }

  void _ok(String id, [Object? result]) =>
      emit('response', {'re': id, 'ok': true, 'result': ?result});

  void _error(String id, String code, String message) => emit('response', {
    're': id,
    'ok': false,
    'error': {'code': code, 'message': message},
  });

  void _changed() {
    if (!disposed) {
      _revision.value += 1;
    }
  }

  // --------------------------------------------------------------- the view

  /// Stands in for the platform view's focus node, which takes Flutter's
  /// focus when the page reports its own.
  final FocusNode viewFocus = FocusNode(debugLabel: 'fake editor view');

  /// How much of the active document the view lays out: more than fits on
  /// a screen at any gate size, even in the smallest font (10 px). The real
  /// page renders only the lines on screen, while laying out all of a
  /// half-megabyte document here (the large-file tests, W7) takes seconds.
  static const int viewChars = 16 * 1024;

  /// The start of the active document as plain text, styled from the
  /// configured palette, so screens and goldens show what the editor would.
  @override
  Widget buildView(BuildContext context) {
    return Focus(
      focusNode: viewFocus,
      includeSemantics: false,
      child: ValueListenableBuilder<int>(
        valueListenable: _revision,
        builder: (context, _, _) {
          final docId = activeDocId;
          final doc = docId == null ? null : documents[docId];
          final palette = configuration?['palette'];
          final foreground = palette is Map<String, Object?>
              ? palette['foreground']
              : null;
          final fontSize = configuration?['fontSize'];
          return ClipRect(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _start(doc?.text ?? ''),
                  key: const ValueKey('fake_editor_text'),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: fontSize is num ? fontSize.toDouble() : 14,
                    height: 1.5,
                    color: foreground is String
                        ? _cssColor(foreground)
                        : const Color(0xFFE8EAF0),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _revision.dispose();
    viewFocus.dispose();
    await _messages.close();
    await _events.close();
  }
}

/// The first [FakeEditorSurface.viewChars] code units of [text], without
/// splitting a surrogate pair.
String _start(String text) {
  const limit = FakeEditorSurface.viewChars;
  if (text.length <= limit) {
    return text;
  }
  final last = text.codeUnitAt(limit - 1);
  final end = last >= 0xD800 && last <= 0xDBFF ? limit - 1 : limit;
  return text.substring(0, end);
}

Color _cssColor(String hex) {
  final rgb = int.parse(hex.substring(1, 7), radix: 16);
  final alpha = hex.length == 9
      ? int.parse(hex.substring(7, 9), radix: 16)
      : 0xFF;
  return Color((alpha << 24) | rgb);
}
