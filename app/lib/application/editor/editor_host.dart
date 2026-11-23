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
///
/// Since Phase 6 W5 the page asks too: its language requests (`lsp.*`) go
/// to the [pageRequestHandler] (application/lsp/lsp_features.dart), and each
/// is answered with one `response`. The host shows a document's diagnostics
/// ([setDiagnostics]) and applies a rename's edits ([applyEdits]).
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show BuildContext, Widget;

import '../../core/editor/journal.dart';
import '../../core/editor/protocol.dart';
import '../../core/editor/rate_limiter.dart';
import '../../core/editor/shadow_document.dart';
import '../../core/editor/webview_floor.dart';
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

/// A started page has every document again (Phase 6 W5): what the page
/// alone held, such as diagnostics, must be sent again.
final class PageSynced extends EditorHostEvent {
  const PageSynced();
}

/// One of the page's requests (Phase 6 W5): `lsp.complete`, `lsp.resolve`,
/// `lsp.hover`, `lsp.definition` or `lsp.prepareRename`, with its validated
/// [payload].
final class PageRequest {
  PageRequest(this.id, this.type, this.payload);

  /// The page's envelope id, which the answer names.
  final String id;
  final String type;
  final Map<String, Object?> payload;
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  /// The page gave up on it (`lsp.cancel`), or went away.
  bool get isCancelled => _cancelled;

  /// Calls [listener] once the request is cancelled (now, if it is).
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void _cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    final listeners = [..._listeners];
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

/// Answers one of the page's requests: the result the page checks against
/// its request ([validatePageResult]), or a failure, whose kind becomes the
/// answer's error code ([pageErrorCode]).
typedef PageRequestHandler = Future<Result<Object?>> Function(PageRequest);

/// One document's edits for [EditorHost.applyEdits]: offsets into its text
/// at [baseVersion], sorted and apart.
typedef DocumentEditsSpec = ({
  String docId,
  int baseVersion,
  List<({int from, int to, String insert})> edits,
});

/// The error code a page request's [failure] is answered with: whether a
/// server could answer at all, the time it took, or what it said.
String pageErrorCode(Failure failure) => switch (failure) {
  LspFailure(:final problem) => switch (problem) {
    LspProblem.timeout => 'timeout',
    LspProblem.cancelled => 'cancelled',
    LspProblem.serverError => 'server_error',
    _ => 'unavailable',
  },
  _ => 'internal',
};

/// A document's text changed: an edit, or a resync from the editor.
final class DocumentEdited extends EditorHostEvent {
  const DocumentEdited(this.docId, this.version, {this.change});

  final String docId;
  final int version;

  /// The edit as the page sent it, for the hot-exit journal. Null when the
  /// text was replaced whole: a shadow rebuilt from the page, or
  /// [EditorHost.replaceText].
  final JournalChange? change;
}

/// The page reported a document's selection or scroll offset
/// (`doc.viewState`); [EditorHost.viewStateOf] has the values.
final class ViewStateChanged extends EditorHostEvent {
  const ViewStateChanged(this.docId);

  final String docId;
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

/// The page's search session changed (`search.state`): opened or closed,
/// a new query, or matches moved under edits and the selection.
final class SearchStateChanged extends EditorHostEvent {
  const SearchStateChanged({
    required this.docId,
    required this.open,
    required this.valid,
    required this.matches,
    required this.current,
    required this.capped,
  });

  final String docId;
  final bool open;

  /// False for an empty query or a broken regular expression.
  final bool valid;

  /// How many matches there are; when [capped], at least this many.
  final int matches;

  /// The 1-based match the main selection covers; 0 when none.
  final int current;
  final bool capped;
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

  /// The page's requests not answered yet, by their ids (Phase 6 W5).
  final Map<String, PageRequest> _pageRequests = {};

  /// Who answers the page's requests; without one they are answered as
  /// unavailable, and completion falls back to the document's words.
  PageRequestHandler? pageRequestHandler;

  /// How many diagnostics the page took for each document, in the last set
  /// it accepted (Phase 6 W5: what it underlines).
  final Map<String, int> _diagnosticsShown = {};

  /// The page's requests answered with a result, by type, and the newest
  /// result of each (Phase 6 W5).
  final Map<String, int> _pageAnswers = {};
  final Map<String, Object?> _lastPageResults = {};

  EditorHostStatus _status = EditorHostStatus.idle;
  String? _activeDocId;
  Map<String, Object?>? _configuration;
  Timer? _readyTimer;
  int _nextRequestId = 0;
  int _pageStarts = 0;
  int _syncs = 0;

  /// The page sync in flight, if any. The host reports ready as soon as the
  /// page announces itself, but until this finishes the page may not have
  /// a document open or active yet. Document commands wait for it.
  Future<void>? _syncing;
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

  /// How many diagnostics the page shows for [docId]: the last set it
  /// accepted (Phase 6 W5); null before any.
  int? diagnosticsShown(String docId) => _diagnosticsShown[docId];

  /// How many of the page's requests of [type] were answered with a result
  /// (Phase 6 W5), and the newest result.
  int pageAnswers(String type) => _pageAnswers[type] ?? 0;
  Object? lastPageResult(String type) => _lastPageResults[type];
  int? versionOf(String docId) => _documents[docId]?.version;

  /// The selection and scroll offset the page last reported for [docId]
  /// (`doc.viewState`), or what it was opened with.
  ({EditorSelection? selection, double scrollTop})? viewStateOf(String docId) {
    final doc = _documents[docId];
    return doc == null
        ? null
        : (selection: doc.selection, scrollTop: doc.scrollTop);
  }

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
        // A WebView older than the page's build target cannot parse it:
        // say what to update instead of waiting for a page that can't start.
        final engine = await _surface.engineMajorVersion();
        if (_disposed) {
          return;
        }
        if (engine != null && engine < minimumWebViewMajor) {
          _fail('webview_too_old', webViewTooOldMessage(engine));
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
    _cancelPageRequests();
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
    _cancelPageRequests();
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
  /// Opens [docId] with [text]. A document restored from the hot-exit
  /// journal passes the [version] its journal reached, so the edits that
  /// follow continue its numbering, and the [selection] and [scrollTop] its
  /// tab had.
  Future<Result<void>> openDocument({
    required String docId,
    required String text,
    required String language,
    bool activate = true,
    bool readOnly = false,
    int version = 0,
    EditorSelection? selection,
    double scrollTop = 0,
  }) async {
    if (_documents.containsKey(docId)) {
      return Err(BridgeFailure('Document $docId is already open.'));
    }
    if (text.contains('\r')) {
      return const Err(
        BridgeFailure('Editor text must use \\n line breaks only.'),
      );
    }
    final doc =
        ShadowDocument(
            docId: docId,
            language: language,
            text: text,
            version: version,
            readOnly: readOnly,
          )
          ..selection = selection
          ..scrollTop = scrollTop;
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
    if (_syncing != null && (!await _afterSync() || _activeDocId != docId)) {
      // Gone, or another document was activated meanwhile and sent its own.
      return const Ok(null);
    }
    return _done(await _request('doc.activate', {'docId': docId}));
  }

  Future<Result<void>> closeDocument(String docId) async {
    _diagnosticsShown.remove(docId);
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
    if (!_ready || (_syncing != null && !await _afterSync())) {
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

  /// Replaces [docId]'s whole text: the user chose the file on disk over
  /// their unsaved edits. Undo history starts over; the cursor stays where
  /// it was, kept inside the new text.
  Future<Result<void>> replaceText(String docId, String text) async {
    if (!_documents.containsKey(docId)) {
      return Err(BridgeFailure('Document $docId is not open.'));
    }
    if (text.contains('\r')) {
      return const Err(
        BridgeFailure('Editor text must use \\n line breaks only.'),
      );
    }
    if (_ready) {
      // Edits still on their way would otherwise land on the new text.
      await flush(docId);
    }
    final doc = _documents[docId];
    if (doc == null) {
      return Err(BridgeFailure('Document $docId is not open.'));
    }
    final version = doc.version + 1;
    doc.resync(text: text, version: version);
    _emit(DocumentEdited(docId, version));
    if (!_ready) {
      return const Ok(null);
    }
    return _done(
      await _request('doc.replace', {
        'docId': docId,
        'text': text,
        'version': version,
      }, timeout: _timeoutFor(text.length)),
    );
  }

  /// Replaces [docId]'s text with [text] only if nothing was typed since
  /// the shadow was at [baseVersion] (Phase 3 W5: a document without
  /// unsaved changes whose file changed outside the app). The page refuses
  /// (`stale`) when its document has moved on or holds edits it has not
  /// sent yet, and then nothing changes here either: the caller treats the
  /// document as having unsaved changes. Undo history starts over; the
  /// cursor and scroll stay as close as the new text allows.
  Future<Result<void>> reloadText(
    String docId,
    String text, {
    required int baseVersion,
  }) async {
    final doc = _documents[docId];
    if (doc == null) {
      return Err(BridgeFailure('Document $docId is not open.'));
    }
    if (text.contains('\r')) {
      return const Err(
        BridgeFailure('Editor text must use \\n line breaks only.'),
      );
    }
    if (doc.version != baseVersion) {
      return Err(
        BridgeFailure(
          'Document $docId is at version ${doc.version}, not $baseVersion.',
          cause: 'stale',
        ),
      );
    }
    final version = baseVersion + 1;
    if (!_ready || (_syncing != null && !await _afterSync())) {
      // No page to ask: the shadow is what the page will be given.
      final current = _documents[docId];
      if (current == null || current.version != baseVersion) {
        return Err(
          BridgeFailure('Document $docId changed meanwhile.', cause: 'stale'),
        );
      }
      current.resync(text: text, version: version);
      _emit(DocumentEdited(docId, version));
      return const Ok(null);
    }
    final replaced = await _request('doc.replace', {
      'docId': docId,
      'text': text,
      'version': version,
      'baseVersion': baseVersion,
    }, timeout: _timeoutFor(text.length));
    switch (replaced) {
      case Err<Object?>(:final failure):
        return Err(failure);
      case Ok<Object?>():
        // The page shows the new text from [version] on; its next edits
        // build on it, so the shadow takes it before any of them arrives.
        _documents[docId]?.resync(text: text, version: version);
        _emit(DocumentEdited(docId, version));
        return const Ok(null);
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
    if (!_ready || (_syncing != null && !await _afterSync())) {
      return const Ok(null);
    }
    return _done(
      await _request('doc.setLanguage', {'docId': docId, 'language': language}),
    );
  }

  /// Sends pending edits now — for one document, or all of them.
  Future<Result<void>> flush([String? docId]) async {
    if (!_ready || (_syncing != null && !await _afterSync())) {
      return const Ok(null);
    }
    return _done(await _request('doc.flush', {'docId': ?docId}));
  }

  /// Inserts [text] at every cursor of the active document.
  Future<Result<void>> insert(String text, {int? cursorOffset}) async {
    if (!_ready || (_syncing != null && !await _afterSync())) {
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
    if (!_ready || (_syncing != null && !await _afterSync())) {
      return const Err(BridgeFailure('The editor is not ready.'));
    }
    return _done(await _request('cmd.exec', {'command': command}));
  }

  /// Opens or updates the page's search session (`search.set`); the
  /// result says whether the query is usable. Counts follow as
  /// [SearchStateChanged] events.
  Future<Result<bool>> search(
    String query, {
    bool caseSensitive = false,
    bool wholeWord = false,
    bool regexp = false,
    String replacement = '',
  }) async {
    if (!_ready || (_syncing != null && !await _afterSync())) {
      return const Err(BridgeFailure('The editor is not ready.'));
    }
    final result = await _request('search.set', {
      'query': query,
      'caseSensitive': caseSensitive,
      'wholeWord': wholeWord,
      'regexp': regexp,
      'replace': replacement,
    });
    return switch (result) {
      Ok<Object?>(:final value) => Ok(
        value is Map<String, Object?> && value['valid'] == true,
      ),
      Err<Object?>(:final failure) => Err(failure),
    };
  }

  /// Moves the cursor of the active document to [line] (and [column]),
  /// both 1-based; the page clamps them to the text.
  Future<Result<void>> gotoLine(int line, {int? column}) async {
    if (!_ready || (_syncing != null && !await _afterSync())) {
      return const Err(BridgeFailure('The editor is not ready.'));
    }
    return _done(
      await _request('cmd.gotoLine', {'line': line, 'column': ?column}),
    );
  }

  // ------------------------------------------------- language features (W5)

  /// Shows [items] as [docId]'s diagnostics at the shadow's [version]
  /// (`diag.set`), in place of the ones before; an empty list clears them.
  /// The page maps them through any edits made since. Without a page there
  /// is nothing to show them in: [PageSynced] says when to send them again.
  Future<Result<void>> setDiagnostics(
    String docId,
    int version,
    List<Map<String, Object?>> items,
  ) async {
    if (!_documents.containsKey(docId)) {
      return Err(BridgeFailure('Document $docId is not open.'));
    }
    if (!_ready || (_syncing != null && !await _afterSync())) {
      return const Ok(null);
    }
    final shown = _done(
      await _request('diag.set', {
        'docId': docId,
        'version': version,
        'items': items,
      }),
    );
    if (shown.isOk && _documents.containsKey(docId)) {
      _diagnosticsShown[docId] = items.length;
    }
    return shown;
  }

  /// Applies a rename's edits to open documents (`doc.applyEdits`), each
  /// document's as one undoable change, all or nothing. Refused (`stale`)
  /// when any document is no longer at its base version; nothing changes
  /// then. On success the edits have already come back as `doc.changed`:
  /// the shadows hold the new text, and [DocumentEdited] went out.
  Future<Result<void>> applyEdits(List<DocumentEditsSpec> documents) async {
    if (!_ready || (_syncing != null && !await _afterSync())) {
      return const Err(BridgeFailure('The editor is not ready.'));
    }
    var chars = 0;
    for (final document in documents) {
      final doc = _documents[document.docId];
      if (doc == null) {
        return Err(BridgeFailure('Document ${document.docId} is not open.'));
      }
      if (doc.version != document.baseVersion) {
        return Err(
          BridgeFailure(
            'Document ${document.docId} is at version ${doc.version}, '
            'not ${document.baseVersion}.',
            cause: 'stale',
          ),
        );
      }
      chars += doc.text.length;
    }
    return _done(
      await _request('doc.applyEdits', {
        'documents': [
          for (final document in documents)
            {
              'docId': document.docId,
              'baseVersion': document.baseVersion,
              'edits': [
                for (final edit in document.edits)
                  {'from': edit.from, 'to': edit.to, 'insert': edit.insert},
              ],
            },
        ],
      }, timeout: _timeoutFor(chars)),
    );
  }

  void _onPageRequest(BridgeMessage message) {
    final request = PageRequest(message.id, message.type, message.payload);
    _pageRequests[message.id] = request;
    final handler = pageRequestHandler;
    final answer = handler == null
        ? Future<Result<Object?>>.value(
            const Err<Object?>(
              LspFailure(
                'Language features are off.',
                problem: LspProblem.stopped,
              ),
            ),
          )
        : handler(request);
    unawaited(
      answer.then(
        (result) => _answerPage(request, result),
        onError: (Object error) => _answerPage(
          request,
          Err(BridgeFailure('${request.type} failed: $error')),
        ),
      ),
    );
  }

  void _answerPage(PageRequest request, Result<Object?> result) {
    if (!identical(_pageRequests[request.id], request)) {
      // Cancelled, or the page restarted: it waits for nothing.
      return;
    }
    _pageRequests.remove(request.id);
    if (_disposed) {
      return;
    }
    final Map<String, Object?> payload;
    switch (result) {
      case Ok<Object?>(:final value):
        assert(
          validatePageResult(request.type, value) == null,
          'the host answered ${request.type} with a result the page '
          'refuses: ${validatePageResult(request.type, value)}',
        );
        payload = {'re': request.id, 'ok': true, 'result': value};
        _pageAnswers[request.type] = pageAnswers(request.type) + 1;
        _lastPageResults[request.type] = value;
      case Err<Object?>(:final failure):
        final message = failure.message;
        payload = {
          're': request.id,
          'ok': false,
          'error': {
            'code': pageErrorCode(failure),
            'message': message.length > 2000
                ? '${message.substring(0, 1999)}…'
                : message,
          },
        };
    }
    _nextRequestId += 1;
    final encoded = BridgeMessage(
      id: 'h$_nextRequestId',
      type: 'response',
      payload: payload,
    ).encode();
    assert(
      parseMessage(encoded, MessageDirection.hostToEditor) is ParsedMessage,
      'the host built a response the protocol rejects',
    );
    unawaited(_post(encoded, request.type));
  }

  /// Sends a message nothing answers (an answer of the host's own).
  Future<void> _post(String encoded, String about) async {
    try {
      await _surface.deliver(encoded);
    } on Object catch (error) {
      appLogger.warn(
        _tag,
        'answer_undelivered',
        fields: {'type': about, 'error': '$error'},
      );
    }
  }

  void _cancelPageRequests() {
    final requests = _pageRequests.values.toList();
    _pageRequests.clear();
    for (final request in requests) {
      request._cancel();
    }
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
      case 'search.state':
        _emit(
          SearchStateChanged(
            docId: payload.string('docId'),
            open: payload.flag('open'),
            valid: payload.flag('valid'),
            matches: payload.integer('matches'),
            current: payload.integer('current'),
            capped: payload.flag('capped'),
          ),
        );
      case 'lsp.complete' ||
          'lsp.resolve' ||
          'lsp.hover' ||
          'lsp.definition' ||
          'lsp.prepareRename':
        _onPageRequest(message);
      case 'lsp.cancel':
        final request = _pageRequests.remove(payload.string('re'));
        request?._cancel();
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
    final sync = _syncPage(_pageStarts);
    _syncing = sync;
    unawaited(sync.whenComplete(() => _syncDone(sync)));
  }

  void _syncDone(Future<void> sync) {
    if (identical(_syncing, sync)) {
      _syncing = null;
    }
  }

  /// Waits for the page sync in flight, then tells whether the page is
  /// still ready. Callers check [_syncing] first, so that with no sync in
  /// flight a command still goes out at once, in call order. A page that
  /// restarts meanwhile starts a newer sync, which is waited for too.
  Future<bool> _afterSync() async {
    var sync = _syncing;
    while (sync != null) {
      await sync;
      final next = _syncing;
      sync = identical(next, sync) ? null : next;
    }
    return _ready;
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
      _emit(const PageSynced());
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
    final baseVersion = payload.integer('baseVersion');
    final version = payload.integer('version');
    final lengthBefore = payload.integer('lengthBefore');
    final lengthAfter = payload.integer('lengthAfter');
    final changes = payload.list('changes');
    final problem = doc.applyChange(
      baseVersion: baseVersion,
      version: version,
      lengthBefore: lengthBefore,
      lengthAfter: lengthAfter,
      changes: changes,
    );
    if (problem == null) {
      _emit(
        DocumentEdited(
          docId,
          doc.version,
          change: JournalChange(
            baseVersion: baseVersion,
            version: version,
            lengthBefore: lengthBefore,
            lengthAfter: lengthAfter,
            changes: changes,
          ),
        ),
      );
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
    _emit(ViewStateChanged(doc.docId));
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
