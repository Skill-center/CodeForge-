/// The host side of the editor bridge (docs/EDITOR_ARCHITECTURE.md §2).
///
/// Owns the editor surface, request/response bookkeeping and the shadow copy
/// of every open document. Each message from the page is rate-limited, then
/// validated against protocol v1 (size cap included) before it is acted on;
/// anything else is dropped and logged.
///
/// The shadows are the host's source of truth for document text: whenever
/// the page (re)announces itself with `editor.ready`, the host sends the
/// configuration and reopens every document from its shadow, so a page
/// restart loses nothing that reached the host.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show BuildContext, Widget;

import '../../core/editor/protocol.dart';
import '../../core/editor/rate_limiter.dart';
import '../../core/editor/shadow_document.dart';
import '../../core/errors/failure.dart';
import '../../core/logging/logger.dart';
import '../../services/editor/editor_page.dart';
import '../../services/editor/editor_surface.dart';

const String _tag = 'editor';

/// Loads and verifies the built page (see services/editor/editor_page.dart).
typedef EditorPageLoader = Future<Result<EditorPage>> Function();

enum EditorHostPhase { idle, loading, ready, failed }

final class EditorHostStatus {
  const EditorHostStatus(this.phase, {this.message, this.engineVersion});

  static const EditorHostStatus idle = EditorHostStatus(EditorHostPhase.idle);

  final EditorHostPhase phase;

  /// Why the editor failed, in words fit for the user.
  final String? message;

  /// The engine version the page announced.
  final String? engineVersion;
}

/// Something the page reported that the app reacts to.
sealed class EditorHostEvent {
  const EditorHostEvent();
}

/// A document's text changed: an edit, or a resync from the editor.
final class DocumentEdited extends EditorHostEvent {
  const DocumentEdited(this.docId, this.version);

  final String docId;
  final int version;
}

final class HistoryChanged extends EditorHostEvent {
  const HistoryChanged({
    required this.docId,
    required this.canUndo,
    required this.canRedo,
  });

  final String docId;
  final bool canUndo;
  final bool canRedo;
}

final class FocusChanged extends EditorHostEvent {
  const FocusChanged(this.focused);

  final bool focused;
}

final class CompositionChanged extends EditorHostEvent {
  const CompositionChanged({required this.docId, required this.composing});

  final String docId;
  final bool composing;
}

/// An app shortcut pressed while the editor had keyboard focus.
final class ShortcutPressed extends EditorHostEvent {
  const ShortcutPressed(this.shortcut);

  /// One of `appShortcuts`.
  final String shortcut;
}

/// The editor's text for one document, with pending edits flushed.
final class EditorSnapshot {
  const EditorSnapshot({
    required this.docId,
    required this.text,
    required this.version,
    this.selection,
    this.scrollTop,
  });

  final String docId;
  final String text;
  final int version;

  /// The main selection, when known.
  final EditorSelection? selection;

  /// The vertical scroll offset; the page reports it for the active
  /// document only.
  final double? scrollTop;
}

final class _PendingRequest {
  _PendingRequest(this.type, this.completer, this.timer);

  final String type;
  final Completer<Result<Object?>> completer;
  final Timer timer;
}

final class EditorHost {
  EditorHost({
    required EditorSurface surface,
    required EditorPageLoader loadPage,
    this.readyTimeout = const Duration(seconds: 20),
    this.requestTimeout = const Duration(seconds: 5),
    MessageRateLimiter? rateLimiter,
  }) : _surface = surface,
       _loadPage = loadPage,
       _limiter = rateLimiter ?? MessageRateLimiter() {
    _messageSubscription = surface.messages.listen(_onMessage);
    _eventSubscription = surface.events.listen(_onSurfaceEvent);
  }

  final EditorSurface _surface;
  final EditorPageLoader _loadPage;
  final MessageRateLimiter _limiter;

  /// How long a loading page may take to announce `editor.ready`.
  final Duration readyTimeout;

  /// Base time a request may wait for its response; whole-document
  /// requests get more in proportion to their size.
  final Duration requestTimeout;

  late final StreamSubscription<String> _messageSubscription;
  late final StreamSubscription<EditorSurfaceEvent> _eventSubscription;
  final StreamController<EditorHostStatus> _statusController =
      StreamController<EditorHostStatus>.broadcast();
  final StreamController<EditorHostEvent> _eventController =
      StreamController<EditorHostEvent>.broadcast();

  /// Open documents in opening order.
  final Map<String, ShadowDocument> _documents = {};
  final Map<String, _PendingRequest> _pending = {};

  EditorHostStatus _status = EditorHostStatus.idle;
  String? _activeDocId;
  Map<String, Object?>? _configuration;
  Timer? _readyTimer;
  int _nextRequestId = 0;
  int _pageStarts = 0;
  int _syncs = 0;
  int _droppedMessages = 0;
  int _resyncs = 0;
  bool _disposed = false;

  EditorHostStatus get status => _status;
  Stream<EditorHostStatus> get statusChanges => _statusController.stream;
  Stream<EditorHostEvent> get events => _eventController.stream;

  /// Times the page announced `editor.ready`; above one means it restarted.
  int get pageStarts => _pageStarts;

  /// Completed page syncs (configuration + every document reopened).
  int get syncs => _syncs;

  /// Messages dropped by the rate limit.
  int get droppedMessages => _droppedMessages;

  /// Times a shadow had to be rebuilt from the editor's text.
  int get resyncs => _resyncs;

  String? get activeDocId => _activeDocId;
  List<String> get documentIds => List.unmodifiable(_documents.keys);
  String? textOf(String docId) => _documents[docId]?.text;
  int? versionOf(String docId) => _documents[docId]?.version;

  /// The widget showing the page. Mount it in one place only: it is the
  /// page, not a picture of it.
  Widget buildView(BuildContext context) => _surface.buildView(context);

  bool get _ready => _status.phase == EditorHostPhase.ready;

  // ------------------------------------------------------------- lifecycle

  /// Loads the page unless it is loading or loaded. Safe to call repeatedly.
  Future<void> start() async {
    if (_disposed ||
        _status.phase == EditorHostPhase.loading ||
        _status.phase == EditorHostPhase.ready) {
      return;
    }
    _setStatus(const EditorHostStatus(EditorHostPhase.loading));
    final page = await _loadPage();
    if (_disposed) {
      return;
    }
    switch (page) {
      case Err<EditorPage>(:final failure):
        _fail('page_rejected', failure.message);
      case Ok<EditorPage>(:final value):
        if (value.protocol != protocolVersion) {
          _fail(
            'page_protocol_mismatch',
            'The editor page speaks protocol ${value.protocol}; '
                'this app needs $protocolVersion.',
          );
          return;
        }
        _armReadyTimer();
        try {
          await _surface.loadPage(value.html);
        } on Object catch (error) {
          _fail('page_load_failed', 'The editor could not be loaded ($error).');
        }
    }
  }

  /// Reloads the page — recovery, or a retry after a failure. Documents are
  /// reopened from their shadows once the page announces itself again.
  Future<void> reloadPage() async {
    if (_disposed) {
      return;
    }
    if (!_ready && _status.phase != EditorHostPhase.loading) {
      return start();
    }
    appLogger.warn(
      _tag,
      'page_reload',
      fields: {'documents': _documents.length},
    );
    _failPending('The editor page is reloading.');
    _setStatus(const EditorHostStatus(EditorHostPhase.loading));
    _armReadyTimer();
    try {
      await _surface.reload();
    } on Object catch (error) {
      _fail('page_reload_failed', 'The editor could not be reloaded ($error).');
    }
  }

  /// Tears the host down. Everything stops synchronously: no timer, request
  /// or subscription outlives this call, and the returned future waits only
  /// for the surface.
  ///
  /// Stream teardown is not awaited on purpose. A cancelled broadcast
  /// subscription reports completion through a future of the root zone.
  /// Awaiting that inside a fake-async zone (a widget test) resumes the
  /// caller outside the zone's control, and whatever it awaits next in the
  /// zone never completes.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _readyTimer?.cancel();
    _failPending('The editor is closed.');
    unawaited(_messageSubscription.cancel());
    unawaited(_eventSubscription.cancel());
    unawaited(_statusController.close());
    unawaited(_eventController.close());
    await _surface.dispose();
  }

  // ------------------------------------------------------------- documents

  /// Sends (and keeps, for page restarts) the editor's appearance: the
  /// `editor.configure` payload.
  Future<Result<void>> configure(Map<String, Object?> configuration) async {
    _configuration = configuration;
    if (!_ready) {
      return const Ok(null);
    }
    return _done(await _request('editor.configure', configuration));
  }

  /// Opens a document; [text] must use "\n" line breaks. While the page is
  /// not ready the document waits in its shadow and opens with the sync.
  Future<Result<void>> openDocument({
    required String docId,
    required String text,
    required String language,
    bool activate = true,
    bool readOnly = false,
  }) async {
    if (_documents.containsKey(docId)) {
      return Err(BridgeFailure('Document $docId is already open.'));
    }
    if (text.contains('\r')) {
      return const Err(
        BridgeFailure('Editor text must use \\n line breaks only.'),
      );
    }
    final doc = ShadowDocument(
      docId: docId,
      language: language,
      text: text,
      readOnly: readOnly,
    );
    _documents[docId] = doc;
    if (activate) {
      _activeDocId = docId;
    }
    if (!_ready) {
      return const Ok(null);
    }
    return _done(
      await _request(
        'doc.open',
        _openPayload(doc, activate: activate),
        timeout: _timeoutFor(text.length),
      ),
    );
  }

  Future<Result<void>> activate(String docId) async {
    if (!_documents.containsKey(docId)) {
      return Err(BridgeFailure('Document $docId is not open.'));
    }
    _activeDocId = docId;
    if (!_ready) {
      return const Ok(null);
    }
    return _done(await _request('doc.activate', {'docId': docId}));
  }

  Future<Result<void>> closeDocument(String docId) async {
    if (_documents.remove(docId) == null) {
      return Err(BridgeFailure('Document $docId is not open.'));
    }
    if (_activeDocId == docId) {
      _activeDocId = null;
    }
    if (!_ready) {
      return const Ok(null);
    }
    return _done(await _request('doc.close', {'docId': docId}));
  }

  /// The editor's current text for [docId], pending edits flushed first.
  /// Cross-checks the shadow and rebuilds it if the two ever disagree.
  Future<Result<EditorSnapshot>> snapshot(String docId) async {
    final doc = _documents[docId];
    if (doc == null) {
      return Err(BridgeFailure('Document $docId is not open.'));
    }
    if (!_ready) {
      // No page to ask: the shadow is the truth.
      return Ok(
        EditorSnapshot(
          docId: docId,
          text: doc.text,
          version: doc.version,
          selection: doc.selection,
          scrollTop: doc.scrollTop,
        ),
      );
    }
    final result = await _request('doc.snapshot', {
      'docId': docId,
    }, timeout: _timeoutFor(doc.text.length));
    switch (result) {
      case Err<Object?>(:final failure):
        return Err(failure);
      case Ok<Object?>(:final value):
        if (value is! Map<String, Object?> ||
            value['text'] is! String ||
            value['version'] is! num) {
          return const Err(
            BridgeFailure('The editor sent a malformed snapshot.'),
          );
        }
        final text = value.string('text');
        final version = value.integer('version');
        if (text.contains('\r')) {
          return const Err(
            BridgeFailure('The editor sent a malformed snapshot.'),
          );
        }
        if (identical(_documents[docId], doc) &&
            (doc.version != version || doc.text != text)) {
          _resync(
            doc,
            text: text,
            version: version,
            reason: 'snapshot differs',
          );
        }
        final selection = value['selection'];
        final scrollTop = value['scrollTop'];
        return Ok(
          EditorSnapshot(
            docId: docId,
            text: text,
            version: version,
            selection:
                selection is Map<String, Object?> &&
                    selection['anchor'] is num &&
                    selection['head'] is num
                ? EditorSelection(
                    anchor: selection.integer('anchor'),
                    head: selection.integer('head'),
                  )
                : null,
            scrollTop: scrollTop is num ? scrollTop.toDouble() : null,
          ),
        );
    }
  }

  /// Highlights [docId] as [language] from now on (Save As to another
  /// extension). Text, cursor and undo history stay as they are.
  Future<Result<void>> setLanguage(String docId, String language) async {
    final doc = _documents[docId];
    if (doc == null) {
      return Err(BridgeFailure('Document $docId is not open.'));
    }
    if (doc.language == language) {
      return const Ok(null);
    }
    // The shadow keeps it too, so a page restart reopens it highlighted.
    doc.language = language;
    if (!_ready) {
      return const Ok(null);
    }
    return _done(
      await _request('doc.setLanguage', {
        'docId': docId,
        'language': language,
      }),
    );
  }

  /// Sends pending edits now — for one document, or all of them.
  Future<Result<void>> flush([String? docId]) async {
    if (!_ready) {
      return const Ok(null);
    }
    return _done(await _request('doc.flush', {'docId': ?docId}));
  }

  /// Inserts [text] at every cursor of the active document.
  Future<Result<void>> insert(String text, {int? cursorOffset}) async {
    if (!_ready) {
      return const Err(BridgeFailure('The editor is not ready.'));
    }
    return _done(
      await _request('cmd.insert', {
        'text': text,
        'cursorOffset': ?cursorOffset,
      }),
    );
  }

  /// Runs one of `editorCommands`.
  Future<Result<void>> exec(String command) async {
    if (!_ready) {
      return const Err(BridgeFailure('The editor is not ready.'));
    }
    return _done(await _request('cmd.exec', {'command': command}));
  }

  // -------------------------------------------------------------- requests

  Future<Result<Object?>> _request(
    String type,
    Map<String, Object?> payload, {
    Duration? timeout,
  }) {
    if (_disposed) {
      return Future.value(const Err(BridgeFailure('The editor is closed.')));
    }
    _nextRequestId += 1;
    final id = 'h$_nextRequestId';
    final encoded = BridgeMessage(
      id: id,
      type: type,
      payload: payload,
    ).encode();
    if (encoded.length > maxMessageChars) {
      return Future.value(
        const Err(
          BridgeFailure(
            'This document is too large for the editor.',
            cause: 'too_large',
          ),
        ),
      );
    }
    assert(
      parseMessage(encoded, MessageDirection.hostToEditor) is ParsedMessage,
      'the host built a $type message the protocol rejects',
    );
    final completer = Completer<Result<Object?>>();
    _pending[id] = _PendingRequest(
      type,
      completer,
      Timer(timeout ?? requestTimeout, () => _timeOut(id)),
    );
    unawaited(_deliver(id, encoded));
    return completer.future;
  }

  Future<void> _deliver(String id, String encoded) async {
    try {
      await _surface.deliver(encoded);
    } on Object catch (error) {
      final pending = _pending.remove(id);
      if (pending != null) {
        pending.timer.cancel();
        pending.completer.complete(
          Err(
            BridgeFailure(
              '${pending.type} could not reach the editor.',
              cause: error,
            ),
          ),
        );
      }
    }
  }

  void _timeOut(String id) {
    final pending = _pending.remove(id);
    if (pending == null) {
      return;
    }
    appLogger.warn(
      _tag,
      'request_timeout',
      fields: {'type': pending.type, 'id': id},
    );
    pending.completer.complete(
      Err(BridgeFailure('${pending.type} timed out.', cause: 'timeout')),
    );
  }

  void _failPending(String reason) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      request.timer.cancel();
      request.completer.complete(Err(BridgeFailure(reason)));
    }
  }

  /// One millisecond per thousand characters on top of the base timeout:
  /// a 10 MB document gets 15 s instead of 5.
  Duration _timeoutFor(int chars) =>
      requestTimeout + Duration(milliseconds: chars ~/ 1000);

  Result<void> _done(Result<Object?> result) => switch (result) {
    Ok<Object?>() => const Ok(null),
    Err<Object?>(:final failure) => Err(failure),
  };

  Map<String, Object?> _openPayload(
    ShadowDocument doc, {
    required bool activate,
  }) {
    final selection = doc.selection;
    return {
      'docId': doc.docId,
      'text': doc.text,
      'language': doc.language,
      'version': doc.version,
      if (doc.readOnly) 'readOnly': true,
      if (selection != null)
        'selection': selection.clampedTo(doc.text.length).toJson(),
      if (doc.scrollTop > 0) 'scrollTop': doc.scrollTop,
      'activate': activate,
    };
  }

  // -------------------------------------------------------------- incoming

  void _onMessage(String raw) {
    if (_disposed) {
      return;
    }
    if (!_limiter.tryAcquire()) {
      _droppedMessages += 1;
      if (_droppedMessages == 1 || _droppedMessages % 100 == 0) {
        appLogger.warn(
          _tag,
          'message_rate_limited',
          fields: {'dropped': _droppedMessages},
        );
      }
      return;
    }
    switch (parseMessage(raw, MessageDirection.editorToHost)) {
      case RejectedMessage(:final code, :final reason):
        appLogger.warn(
          _tag,
          'message_rejected',
          fields: {'code': code, 'reason': reason},
        );
      case ParsedMessage(:final message):
        _dispatch(message);
    }
  }

  void _dispatch(BridgeMessage message) {
    final payload = message.payload;
    switch (message.type) {
      case 'response':
        _onResponse(payload);
      case 'editor.ready':
        _onReady(payload);
      case 'doc.changed':
        _onChanged(payload);
      case 'doc.viewState':
        _onViewState(payload);
      case 'editor.history':
        _emit(
          HistoryChanged(
            docId: payload.string('docId'),
            canUndo: payload.flag('canUndo'),
            canRedo: payload.flag('canRedo'),
          ),
        );
      case 'editor.focus':
        _emit(FocusChanged(payload.flag('focused')));
      case 'ime.composition':
        _emit(
          CompositionChanged(
            docId: payload.string('docId'),
            composing: payload.flag('composing'),
          ),
        );
      case 'app.shortcut':
        _emit(ShortcutPressed(payload.string('shortcut')));
      case 'editor.log':
        appLogger.log(
          LogLevel.values.byName(payload.string('level')),
          'editor.page',
          'log',
          fields: {'message': _clip(payload.string('message'))},
        );
    }
  }

  void _onResponse(Map<String, Object?> payload) {
    final re = payload.string('re');
    final pending = _pending.remove(re);
    if (pending == null) {
      appLogger.debug(_tag, 'response_unmatched', fields: {'re': re});
      return;
    }
    pending.timer.cancel();
    if (payload.flag('ok')) {
      pending.completer.complete(Ok(payload['result']));
      return;
    }
    final error = payload.object('error');
    final code = error.string('code');
    appLogger.warn(
      _tag,
      'request_failed',
      fields: {'type': pending.type, 'code': code},
    );
    pending.completer.complete(
      Err(
        BridgeFailure(
          '${pending.type} failed: ${error.string('message')}',
          cause: code,
        ),
      ),
    );
  }

  void _onReady(Map<String, Object?> payload) {
    final protocol = payload.integer('protocol');
    if (protocol != protocolVersion) {
      _fail(
        'page_protocol_mismatch',
        'The editor speaks protocol $protocol; this app needs '
            '$protocolVersion.',
      );
      return;
    }
    _readyTimer?.cancel();
    _readyTimer = null;
    _pageStarts += 1;
    if (_pageStarts > 1) {
      // The page restarted under us: whatever was in flight is gone.
      appLogger.warn(
        _tag,
        'page_restarted',
        fields: {'starts': _pageStarts, 'documents': _documents.length},
      );
      _failPending('The editor page restarted.');
    }
    final engineVersion = payload.string('engineVersion');
    appLogger.info(
      _tag,
      'page_ready',
      fields: {'engine': payload.string('engine'), 'version': engineVersion},
    );
    _setStatus(
      EditorHostStatus(EditorHostPhase.ready, engineVersion: engineVersion),
    );
    unawaited(_syncPage(_pageStarts));
  }

  /// Brings a freshly started page up to date: configuration, every open
  /// document from its shadow, then the active document.
  Future<void> _syncPage(int start) async {
    bool stale() => _disposed || start != _pageStarts || !_ready;
    // Copied before the first await: documents opened from here on go out
    // through openDocument (the page is ready), and must not open twice.
    final documents = _documents.values.toList();
    final configuration = _configuration;
    if (configuration != null) {
      await _request('editor.configure', configuration);
    }
    for (final doc in documents) {
      if (stale()) {
        return;
      }
      if (!identical(_documents[doc.docId], doc)) {
        continue;
      }
      final result = await _request(
        'doc.open',
        _openPayload(doc, activate: false),
        timeout: _timeoutFor(doc.text.length),
      );
      if (result case Err<Object?>(:final failure)) {
        appLogger.error(
          _tag,
          'reopen_failed',
          fields: {'docId': doc.docId, 'error': failure.message},
        );
      }
    }
    if (stale()) {
      return;
    }
    final active = _activeDocId;
    if (active != null && _documents.containsKey(active)) {
      await _request('doc.activate', {'docId': active});
    }
    if (!stale()) {
      _syncs += 1;
      appLogger.info(
        _tag,
        'page_synced',
        fields: {'documents': _documents.length, 'starts': _pageStarts},
      );
    }
  }

  void _onChanged(Map<String, Object?> payload) {
    final docId = payload.string('docId');
    final doc = _documents[docId];
    if (doc == null) {
      // Edits flushed while a document closes arrive after it is gone.
      appLogger.debug(
        _tag,
        'change_for_closed_document',
        fields: {'docId': docId},
      );
      return;
    }
    final problem = doc.applyChange(
      baseVersion: payload.integer('baseVersion'),
      version: payload.integer('version'),
      lengthBefore: payload.integer('lengthBefore'),
      lengthAfter: payload.integer('lengthAfter'),
      changes: payload.list('changes'),
    );
    if (problem == null) {
      _emit(DocumentEdited(docId, doc.version));
      return;
    }
    appLogger.error(
      _tag,
      'change_refused',
      fields: {'docId': docId, 'reason': problem},
    );
    // The editor holds what the user sees: rebuild the shadow from it.
    unawaited(snapshot(docId));
  }

  void _onViewState(Map<String, Object?> payload) {
    final doc = _documents[payload.string('docId')];
    if (doc == null) {
      return;
    }
    final selection = payload.object('selection');
    doc
      ..selection = EditorSelection(
        anchor: selection.integer('anchor'),
        head: selection.integer('head'),
      )
      ..scrollTop = payload.number('scrollTop');
  }

  void _resync(
    ShadowDocument doc, {
    required String text,
    required int version,
    required String reason,
  }) {
    _resyncs += 1;
    appLogger.error(
      _tag,
      'shadow_resync',
      fields: {
        'docId': doc.docId,
        'reason': reason,
        'shadowVersion': doc.version,
        'editorVersion': version,
      },
    );
    doc.resync(text: text, version: version);
    _emit(DocumentEdited(doc.docId, version));
  }

  void _onSurfaceEvent(EditorSurfaceEvent event) {
    switch (event) {
      case SurfacePageLoaded():
        appLogger.debug(_tag, 'page_loaded');
      case SurfaceLoadFailed(:final description):
        appLogger.error(
          _tag,
          'page_resource_error',
          fields: {'error': description},
        );
      case SurfaceNavigationBlocked(:final url):
        appLogger.warn(_tag, 'navigation_blocked', fields: {'url': _clip(url)});
      case SurfaceConsoleMessage(:final level, :final message):
        appLogger.debug(
          'editor.console',
          level,
          fields: {'message': _clip(message)},
        );
    }
  }

  // --------------------------------------------------------------- helpers

  void _armReadyTimer() {
    _readyTimer?.cancel();
    _readyTimer = Timer(readyTimeout, () {
      if (_status.phase == EditorHostPhase.loading) {
        _fail(
          'ready_timeout',
          'The editor did not start within ${readyTimeout.inSeconds} s.',
        );
      }
    });
  }

  void _fail(String event, String message) {
    appLogger.error(_tag, event, fields: {'message': message});
    _readyTimer?.cancel();
    _readyTimer = null;
    _failPending(message);
    _setStatus(EditorHostStatus(EditorHostPhase.failed, message: message));
  }

  void _setStatus(EditorHostStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  void _emit(EditorHostEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  /// Log lines stay short; page output can be arbitrarily long.
  static String _clip(String text) =>
      text.length <= 300 ? text : '${text.substring(0, 300)}…';
}
