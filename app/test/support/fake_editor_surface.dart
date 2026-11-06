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
  });

  String text;
  int version;
  final String language;
}

final class FakeEditorSurface implements EditorSurface {
  FakeEditorSurface({this.announceReady = true, this.respond = true});

  /// Whether a loaded page announces `editor.ready` (false: a page that
  /// never starts).
  bool announceReady;

  /// Whether requests get responses (false: a hung page).
  bool respond;

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
  Map<String, Object?>? configuration;
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
        if (respond) {
          _handle(parsed);
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
          doc
            ..text = payload.string('text')
            ..version = payload.integer('version');
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
        _ok(id, {'ran': true});
      default:
        // doc.flush (edits are never held back here), cmd.gotoLine,
        // search.set.
        _ok(id);
    }
  }

  void _open(String id, Map<String, Object?> payload) {
    final docId = payload.string('docId');
    if (documents.containsKey(docId)) {
      _error(id, 'doc_exists', 'document $docId is already open');
      return;
    }
    documents[docId] = FakeDocument(
      text: payload.string('text'),
      version: payload.integer('version'),
      language: payload.string('language'),
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
    if (docId == null || !documents.containsKey(docId)) {
      _error(id, 'no_active_doc', 'no document is active');
      return;
    }
    // The cursor of a freshly opened document sits at its start.
    _change(docId, at: 0, delete: 0, insert: payload.string('text'));
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
  }

  void _ok(String id, [Object? result]) => emit('response', {
    're': id,
    'ok': true,
    if (result != null) 'result': result,
  });

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

  /// The active document as plain text, styled from the configured palette,
  /// so screens and goldens show what the editor would.
  @override
  Widget buildView(BuildContext context) {
    return ValueListenableBuilder<int>(
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
                doc?.text ?? '',
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
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _revision.dispose();
    await _messages.close();
    await _events.close();
  }
}

Color _cssColor(String hex) {
  final rgb = int.parse(hex.substring(1, 7), radix: 16);
  final alpha = hex.length == 9
      ? int.parse(hex.substring(7, 9), radix: 16)
      : 0xFF;
  return Color((alpha << 24) | rgb);
}
