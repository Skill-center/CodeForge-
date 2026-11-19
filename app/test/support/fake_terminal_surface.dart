/// A scripted terminal page in Dart (Phase 5 W3). It speaks the terminal
/// protocol v1 over the EditorSurface interface and validates every host
/// message with the same rules as the real page, so widget and controller
/// tests exercise the real TerminalView and TerminalController without a
/// WebView (platform views cannot run under `flutter test`). The real page
/// runs under vitest (editor/test/terminal_*.test.ts), in
/// editor/tool/verify_terminal.mjs, and on the emulator
/// (integration_test/terminal_test.dart).
library;

import 'dart:async';

import 'package:codeforge/application/terminal/terminal_providers.dart';
import 'package:codeforge/application/terminal/terminal_view.dart';
import 'package:codeforge/core/editor/protocol.dart'
    show BridgeMessage, ParsedMessage, RejectedMessage;
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/terminal/terminal_protocol.dart';
import 'package:codeforge/services/editor/editor_surface.dart';
import 'package:codeforge/services/terminal/terminal_page.dart';
import 'package:flutter/widgets.dart';
// Riverpod 3 exports Override from misc.dart, not the main library.
import 'package:flutter_riverpod/misc.dart' show Override;

/// Stands in for the bundled page: no asset reads, no hashing.
const TerminalPage fakeTerminalPage = TerminalPage(
  html: '<!doctype html><title>fake terminal</title>',
  sha256: 'fake',
  engineVersion: '0.0.0',
  protocol: terminalProtocolVersion,
);

/// Overrides that run the terminal page on scripted surfaces. [onCreate]
/// sees each surface created; [loadPage] replaces the stand-in page.
List<Override> fakeTerminalOverrides([
  void Function(FakeTerminalSurface surface)? onCreate,
  TerminalPageLoader? loadPage,
]) {
  return [
    terminalSurfaceFactoryProvider.overrideWithValue(() {
      final surface = FakeTerminalSurface();
      onCreate?.call(surface);
      return surface;
    }),
    terminalPageLoaderProvider.overrideWithValue(
      loadPage ?? () async => const Ok(fakeTerminalPage),
    ),
  ];
}

/// One session's view in the scripted page.
final class FakeTerminalSession {
  FakeTerminalSession(this.sessionId);

  final int sessionId;

  /// What was written, in order (escapes included).
  final StringBuffer written = StringBuffer();

  /// The sequence numbers written, in order.
  final List<int> seqs = [];

  /// What `session.snapshot` answers for the screen.
  List<String> screen = const [];

  /// What `session.copy` answers.
  String selection = '';
  int clears = 0;
}

final class FakeTerminalSurface implements EditorSurface {
  FakeTerminalSurface({this.columns = 64, this.rows = 18});

  /// The size the page fits a new view to.
  int columns;
  int rows;

  /// Whether a loaded page announces itself.
  bool announceReady = true;

  /// Whether writes are acknowledged as they arrive (false: the test
  /// acknowledges with [acknowledge], as a slow xterm.js would).
  bool autoAck = true;

  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<EditorSurfaceEvent> _events =
      StreamController<EditorSurfaceEvent>.broadcast();

  /// Every valid host message, in arrival order.
  final List<BridgeMessage> received = [];

  /// Error codes of host messages this page rejected.
  final List<String> rejected = [];

  final Map<int, FakeTerminalSession> sessions = {};
  int? activeId;
  Map<String, Object?>? configuration;
  bool focused = false;
  ({bool ctrl, bool alt}) modifiers = (ctrl: false, alt: false);

  /// `session.key` messages: the key and its modifiers.
  final List<({int sessionId, String key, bool ctrl, bool alt})> keys = [];

  /// `session.paste` texts, as the host sent them.
  final List<({int sessionId, String text})> pastes = [];

  /// `session.select` actions.
  final List<String> selects = [];

  /// Writes waiting for [acknowledge] when [autoAck] is off.
  final List<({int sessionId, int seq})> unacknowledged = [];

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
  Future<int?> engineMajorVersion() async => null;

  @override
  Future<void> loadPage(String html) async {
    loads += 1;
    _startPage();
  }

  @override
  Future<void> reload() async {
    reloads += 1;
    _startPage();
  }

  /// What a page restart looks like from inside: every view forgotten.
  void restartPage() => _startPage();

  void _startPage() {
    sessions.clear();
    activeId = null;
    configuration = null;
    unacknowledged.clear();
    if (announceReady) {
      emit('terminal.ready', {
        'protocol': terminalProtocolVersion,
        'engine': 'fake',
        'engineVersion': '0.0.0',
      });
    }
  }

  @override
  Future<void> deliver(String message) async {
    switch (parseTerminalMessage(message, TerminalDirection.hostToTerminal)) {
      case RejectedMessage(:final code, :final reason, :final id):
        rejected.add(code);
        if (id != null) {
          _error(id, code, reason);
        }
      case ParsedMessage(message: final parsed):
        received.add(parsed);
        _handle(parsed);
    }
  }

  void _handle(BridgeMessage message) {
    final payload = message.payload;
    final id = payload['sessionId'];
    final session = id is int ? sessions[id] : null;
    bool missing() {
      if (session != null) {
        return false;
      }
      _error(message.id, 'unknown_session', 'no view for session $id');
      return true;
    }

    switch (message.type) {
      case 'terminal.configure':
        configuration = {...?configuration, ...payload};
        _ok(message.id);
      case 'terminal.focus':
        focused = payload['focused'] == true;
        _ok(message.id);
      case 'terminal.modifiers':
        modifiers = (
          ctrl: payload['ctrl'] == true,
          alt: payload['alt'] == true,
        );
        _ok(message.id);
      case 'session.open':
        final sessionId = payload['sessionId']! as int;
        if (sessions.containsKey(sessionId)) {
          _error(message.id, 'session_exists', 'session $sessionId has one');
          return;
        }
        sessions[sessionId] = FakeTerminalSession(sessionId);
        if (payload['activate'] != false) {
          activeId = sessionId;
        }
        _ok(message.id, {'cols': columns, 'rows': rows});
      case 'session.activate':
        if (missing()) {
          return;
        }
        activeId = session!.sessionId;
        _ok(message.id);
      case 'session.close':
        if (missing()) {
          return;
        }
        sessions.remove(session!.sessionId);
        if (activeId == session.sessionId) {
          activeId = null;
        }
        _ok(message.id);
      case 'session.write':
        if (missing()) {
          return;
        }
        final seq = payload['seq']! as int;
        session!.written.write(payload['data']! as String);
        session.seqs.add(seq);
        if (autoAck) {
          emit('session.ack', {'sessionId': session.sessionId, 'seq': seq});
        } else {
          unacknowledged.add((sessionId: session.sessionId, seq: seq));
        }
      case 'session.clear':
        if (missing()) {
          return;
        }
        session!.clears += 1;
        _ok(message.id);
      case 'session.paste':
        if (missing()) {
          return;
        }
        pastes.add((
          sessionId: session!.sessionId,
          text: payload['text']! as String,
        ));
        _ok(message.id);
      case 'session.key':
        if (missing()) {
          return;
        }
        keys.add((
          sessionId: session!.sessionId,
          key: payload['key']! as String,
          ctrl: payload['ctrl'] == true,
          alt: payload['alt'] == true,
        ));
        _ok(message.id);
      case 'session.select':
        if (missing()) {
          return;
        }
        selects.add(payload['action']! as String);
        if (payload['action'] == 'none') {
          session!.selection = '';
        }
        _ok(message.id);
      case 'session.copy':
        if (missing()) {
          return;
        }
        _ok(message.id, {'text': session!.selection});
      case 'session.snapshot':
        if (missing()) {
          return;
        }
        _ok(message.id, {
          'cols': columns,
          'rows': rows,
          'buffer': 'normal',
          'cursorX': 0,
          'cursorY': 0,
          'screen': session!.screen,
          'scrollback': const <String>[],
          'wrapped': 0,
        });
    }
  }

  /// Acknowledges the oldest waiting write (when [autoAck] is off).
  void acknowledge() {
    final next = unacknowledged.removeAt(0);
    emit('session.ack', {'sessionId': next.sessionId, 'seq': next.seq});
  }

  // ------------------------------------------------- what the page reports

  /// The user typed [data] into session [sessionId]'s terminal.
  void type(int sessionId, String data, {bool binary = false}) => emit(
    'session.input',
    {'sessionId': sessionId, 'data': data, if (binary) 'binary': true},
  );

  /// The panel changed size: the view of [sessionId] refitted.
  void resize(int sessionId, {required int columns, required int rows}) =>
      emit('session.resized', {
        'sessionId': sessionId,
        'cols': columns,
        'rows': rows,
      });

  /// A long press selected [text] in session [sessionId].
  void select(int sessionId, String text) {
    sessions[sessionId]?.selection = text;
    emit('session.selection', {
      'sessionId': sessionId,
      'active': text.isNotEmpty,
    });
  }

  void reportFocus({required bool focused}) {
    this.focused = focused;
    emit('terminal.focus', {'focused': focused});
  }

  /// The latched modifiers were used by a typed key.
  void releaseModifiers() {
    modifiers = (ctrl: false, alt: false);
    emit('terminal.modifiers', {'ctrl': false, 'alt': false});
  }

  void title(int sessionId, String title) =>
      emit('session.title', {'sessionId': sessionId, 'title': title});

  void bell(int sessionId) => emit('session.bell', {'sessionId': sessionId});

  void emitRaw(String raw) {
    if (!_messages.isClosed) {
      _messages.add(raw);
    }
  }

  /// Posts a well-formed page → host message.
  void emit(String type, Map<String, Object?> payload) {
    _nextId += 1;
    emitRaw(
      BridgeMessage(id: 't$_nextId', type: type, payload: payload).encode(),
    );
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

  // --------------------------------------------------------------- the view

  @override
  Widget buildView(BuildContext context) {
    return const SizedBox.expand(key: ValueKey('fake_terminal_page'));
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _messages.close();
    await _events.close();
  }
}
