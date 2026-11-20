/// The terminal page's host (Phase 5 W3; docs/TERMINAL_ARCHITECTURE.md §2):
/// loads the verified page into its surface, speaks the terminal protocol
/// v1 with it, and turns what the page says into [TerminalViewEvent]s.
///
/// It knows nothing of sessions' processes: [TerminalController] pairs it
/// with the TerminalService. Like the editor host, it never trusts the page:
/// every message is validated (core/terminal/terminal_protocol.dart) and
/// rate-limited, and a page that does not start in time is a failure the
/// pane can retry.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/editor/protocol.dart'
    show BridgeMessage, ParsedMessage, PayloadReader, RejectedMessage;
import '../../core/editor/rate_limiter.dart';
import '../../core/editor/webview_floor.dart';
import '../../core/errors/failure.dart';
import '../../core/logging/logger.dart';
import '../../core/terminal/terminal_protocol.dart';
import '../../services/editor/editor_surface.dart';
import '../../services/terminal/terminal_page.dart';

const String _tag = 'terminal.view';

/// Loads and verifies the terminal page (services/terminal/terminal_page).
typedef TerminalPageLoader = Future<Result<TerminalPage>> Function();

/// What the terminal says about a WebView older than [minimumWebViewMajor].
String terminalWebViewTooOldMessage(int major) =>
    "This phone's Android System WebView is version $major, and the terminal "
    'needs version $minimumWebViewMajor or later. Update Android System '
    'WebView (or Chrome) from the Play Store, then reopen CodeForge.';

enum TerminalViewPhase { idle, loading, ready, failed }

final class TerminalViewStatus {
  const TerminalViewStatus(this.phase, {this.message, this.engineVersion});

  static const TerminalViewStatus idle = TerminalViewStatus(
    TerminalViewPhase.idle,
  );

  final TerminalViewPhase phase;

  /// Why the page failed, for the pane.
  final String? message;

  /// xterm.js's version, once the page announced itself.
  final String? engineVersion;
}

/// Something the page reported.
sealed class TerminalViewEvent {
  const TerminalViewEvent();
}

/// The page announced itself: a first start, or a restart after which every
/// session's view is gone ([starts] above one).
final class TerminalPageStarted extends TerminalViewEvent {
  const TerminalPageStarted(this.starts);

  final int starts;
}

/// Keys, the input method's text or a mouse report for session [sessionId]:
/// text, or bytes as characters when [binary].
final class TerminalInput extends TerminalViewEvent {
  const TerminalInput(this.sessionId, this.data, {this.binary = false});

  final int sessionId;
  final String data;
  final bool binary;
}

/// The view of [sessionId] has a new size (the panel's).
final class TerminalResized extends TerminalViewEvent {
  const TerminalResized(
    this.sessionId, {
    required this.columns,
    required this.rows,
  });

  final int sessionId;
  final int columns;
  final int rows;
}

/// xterm.js parsed the write [seq] of [sessionId].
final class TerminalAcknowledged extends TerminalViewEvent {
  const TerminalAcknowledged(this.sessionId, this.seq);

  final int sessionId;
  final int seq;
}

final class TerminalTitled extends TerminalViewEvent {
  const TerminalTitled(this.sessionId, this.title);

  final int sessionId;
  final String title;
}

final class TerminalBell extends TerminalViewEvent {
  const TerminalBell(this.sessionId);

  final int sessionId;
}

/// A link the user tapped (W4 opens `file:line` links).
final class TerminalLinkTapped extends TerminalViewEvent {
  const TerminalLinkTapped(this.sessionId, this.text);

  final int sessionId;
  final String text;
}

final class TerminalSelectionChanged extends TerminalViewEvent {
  const TerminalSelectionChanged(this.sessionId, {required this.active});

  final int sessionId;
  final bool active;
}

/// The page's terminal took or lost the keyboard.
final class TerminalFocusChanged extends TerminalViewEvent {
  const TerminalFocusChanged({required this.focused});

  final bool focused;
}

/// The latched Ctrl and Alt changed in the page (they were used).
final class TerminalModifiersChanged extends TerminalViewEvent {
  const TerminalModifiersChanged({required this.ctrl, required this.alt});

  final bool ctrl;
  final bool alt;
}

/// A session's screen, as `session.snapshot` returns it.
final class TerminalSnapshot {
  const TerminalSnapshot({
    required this.columns,
    required this.rows,
    required this.alternate,
    required this.cursorX,
    required this.cursorY,
    required this.screen,
    required this.scrollback,
    required this.wrapped,
  });

  factory TerminalSnapshot.fromJson(Map<String, Object?> json) {
    return TerminalSnapshot(
      columns: json.integer('cols'),
      rows: json.integer('rows'),
      alternate: json.string('buffer') == 'alternate',
      cursorX: json.integer('cursorX'),
      cursorY: json.integer('cursorY'),
      screen: [for (final line in json.list('screen')) line! as String],
      scrollback: [for (final line in json.list('scrollback')) line! as String],
      wrapped: json.integer('wrapped'),
    );
  }

  final int columns;
  final int rows;

  /// Whether a full-screen program (nano, less, vim) has the screen.
  final bool alternate;
  final int cursorX;
  final int cursorY;

  /// The screen's rows, top to bottom, trailing spaces trimmed.
  final List<String> screen;

  /// The lines above the screen that were asked for, oldest first.
  final List<String> scrollback;

  /// Screen rows that continue the row above.
  final int wrapped;
}

final class _Pending {
  _Pending(this.type, this.completer, this.timer);

  final String type;
  final Completer<Result<Object?>> completer;
  final Timer timer;
}

final class TerminalView {
  TerminalView({
    required EditorSurface surface,
    required TerminalPageLoader loadPage,
    this.readyTimeout = const Duration(seconds: 20),
    this.requestTimeout = const Duration(seconds: 5),
    MessageRateLimiter? rateLimiter,
  }) : _surface = surface,
       _loadPage = loadPage,
       // Input, acknowledgements and reports: several hundred a second
       // while a flood is drawn in every session at once.
       _limiter =
           rateLimiter ??
           MessageRateLimiter(capacity: 2000, refillPerSecond: 1000) {
    _messageSubscription = surface.messages.listen(_onMessage);
    _eventSubscription = surface.events.listen(_onSurfaceEvent);
  }

  final EditorSurface _surface;
  final TerminalPageLoader _loadPage;
  final MessageRateLimiter _limiter;

  /// How long a loading page may take to announce `terminal.ready`.
  final Duration readyTimeout;

  /// How long a request may wait for its response.
  final Duration requestTimeout;

  late final StreamSubscription<String> _messageSubscription;
  late final StreamSubscription<EditorSurfaceEvent> _eventSubscription;
  final StreamController<TerminalViewStatus> _statusController =
      StreamController<TerminalViewStatus>.broadcast();
  final StreamController<TerminalViewEvent> _eventController =
      StreamController<TerminalViewEvent>.broadcast();
  final Map<String, _Pending> _pending = {};

  TerminalViewStatus _status = TerminalViewStatus.idle;
  Map<String, Object?>? _configuration;
  Timer? _readyTimer;
  int _nextId = 0;
  int _pageStarts = 0;
  int _droppedMessages = 0;
  bool _disposed = false;

  TerminalViewStatus get status => _status;
  Stream<TerminalViewStatus> get statusChanges => _statusController.stream;
  Stream<TerminalViewEvent> get events => _eventController.stream;

  /// Times the page announced itself; above one means it restarted.
  int get pageStarts => _pageStarts;

  /// Messages dropped by the rate limit.
  int get droppedMessages => _droppedMessages;

  bool get isReady => _status.phase == TerminalViewPhase.ready;

  /// The widget showing the page. Mount it in one place only.
  Widget buildView(BuildContext context) => _surface.buildView(context);

  // ------------------------------------------------------------- lifecycle

  /// Loads the page unless it is loading or loaded. Safe to call repeatedly.
  Future<void> start() async {
    if (_disposed ||
        _status.phase == TerminalViewPhase.loading ||
        _status.phase == TerminalViewPhase.ready) {
      return;
    }
    _setStatus(const TerminalViewStatus(TerminalViewPhase.loading));
    final page = await _loadPage();
    if (_disposed) {
      return;
    }
    switch (page) {
      case Err<TerminalPage>(:final failure):
        _fail('page_rejected', failure.message);
      case Ok<TerminalPage>(:final value):
        if (value.protocol != terminalProtocolVersion) {
          _fail(
            'page_protocol_mismatch',
            'The terminal page speaks protocol ${value.protocol}; this app '
                'needs $terminalProtocolVersion.',
          );
          return;
        }
        // The page is built for the editor's floor (Chrome 87): an older
        // WebView cannot parse it, so say what to update instead of
        // waiting for a page that cannot start.
        final engine = await _surface.engineMajorVersion();
        if (_disposed) {
          return;
        }
        if (engine != null && engine < minimumWebViewMajor) {
          _fail('webview_too_old', terminalWebViewTooOldMessage(engine));
          return;
        }
        _armReadyTimer();
        try {
          await _surface.loadPage(value.html);
        } on Object catch (error) {
          _fail(
            'page_load_failed',
            'The terminal could not be loaded ($error).',
          );
        }
    }
  }

  /// Loads the page again: a retry after a failure, or recovery. The
  /// sessions' views come back through [TerminalPageStarted].
  Future<void> reloadPage() async {
    if (_disposed) {
      return;
    }
    if (_status.phase != TerminalViewPhase.ready &&
        _status.phase != TerminalViewPhase.loading) {
      return start();
    }
    appLogger.warn(_tag, 'page_reload');
    _failPending('The terminal page is reloading.');
    _setStatus(const TerminalViewStatus(TerminalViewPhase.loading));
    _armReadyTimer();
    try {
      await _surface.reload();
    } on Object catch (error) {
      _fail(
        'page_reload_failed',
        'The terminal could not be reloaded ($error).',
      );
    }
  }

  /// Tears the view down; nothing outlives this call but the surface's
  /// own disposal (see EditorHost.dispose for why streams are not awaited).
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _readyTimer?.cancel();
    _failPending('The terminal is closed.');
    unawaited(_messageSubscription.cancel());
    unawaited(_eventSubscription.cancel());
    unawaited(_statusController.close());
    unawaited(_eventController.close());
    await _surface.dispose();
  }

  // -------------------------------------------------------------- requests

  /// The terminals' appearance (`terminal.configure`), kept for restarts.
  Future<Result<void>> configure(Map<String, Object?> configuration) async {
    _configuration = configuration;
    if (!isReady) {
      return const Ok(null);
    }
    return _done(await _request('terminal.configure', configuration));
  }

  /// A view for [sessionId]; answers the size it fitted to the panel.
  Future<Result<({int columns, int rows})>> open(
    int sessionId, {
    bool activate = true,
  }) async {
    final result = await _request('session.open', {
      'sessionId': sessionId,
      if (!activate) 'activate': false,
    });
    return switch (result) {
      Ok(:final value) => _size(value),
      Err(:final failure) => Err(failure),
    };
  }

  Future<Result<void>> activate(int sessionId) async =>
      _done(await _request('session.activate', {'sessionId': sessionId}));

  Future<Result<void>> close(int sessionId) async =>
      _done(await _request('session.close', {'sessionId': sessionId}));

  /// Output for [sessionId], in order. No response: the page answers with
  /// `session.ack` ([TerminalAcknowledged]) once it has parsed [data].
  /// False when the page is not ready, or the message would be too large.
  bool write(int sessionId, int seq, String data) {
    if (_disposed || !isReady || data.length > maxWriteChars) {
      return false;
    }
    _nextId += 1;
    final encoded = BridgeMessage(
      id: 'h$_nextId',
      type: 'session.write',
      payload: {'sessionId': sessionId, 'seq': seq, 'data': data},
    ).encode();
    unawaited(
      _surface.deliver(encoded).catchError((Object error) {
        appLogger.warn(_tag, 'write_failed', fields: {'error': '$error'});
      }),
    );
    return true;
  }

  Future<Result<void>> clear(int sessionId) async =>
      _done(await _request('session.clear', {'sessionId': sessionId}));

  /// Pastes [text], which the page sanitizes (control characters dropped)
  /// and brackets when the program asked for bracketed paste.
  Future<Result<void>> paste(int sessionId, String text) async {
    if (text.length > maxPasteChars) {
      return const Err(
        TerminalFailure(
          'That text is too long to paste into a terminal.',
          problem: TerminalProblem.badRequest,
        ),
      );
    }
    return _done(
      await _request('session.paste', {'sessionId': sessionId, 'text': text}),
    );
  }

  /// An extra key ([terminalKeyNames], or one printable character).
  Future<Result<void>> key(
    int sessionId,
    String key, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) async => _done(
    await _request('session.key', {
      'sessionId': sessionId,
      'key': key,
      if (ctrl) 'ctrl': true,
      if (alt) 'alt': true,
      if (shift) 'shift': true,
    }),
  );

  /// Selects everything ([all]) or nothing.
  Future<Result<void>> select(int sessionId, {required bool all}) async =>
      _done(
        await _request('session.select', {
          'sessionId': sessionId,
          'action': all ? 'all' : 'none',
        }),
      );

  /// The selection's text ('' when there is none).
  Future<Result<String>> copy(int sessionId) async {
    final result = await _request('session.copy', {'sessionId': sessionId});
    return switch (result) {
      Ok(:final value)
          when value is Map<String, Object?> && value['text'] is String =>
        Ok(value['text']! as String),
      Ok() => const Err(BridgeFailure('The terminal answered copy oddly.')),
      Err(:final failure) => Err(failure),
    };
  }

  Future<Result<TerminalSnapshot>> snapshot(
    int sessionId, {
    int scrollback = 0,
  }) async {
    final result = await _request('session.snapshot', {
      'sessionId': sessionId,
      if (scrollback > 0) 'scrollback': scrollback,
    });
    switch (result) {
      case Ok(:final value) when value is Map<String, Object?>:
        try {
          return Ok(TerminalSnapshot.fromJson(value));
        } on Object catch (error) {
          return Err(
            BridgeFailure(
              'The terminal answered a snapshot oddly.',
              cause: error,
            ),
          );
        }
      case Ok():
        return const Err(
          BridgeFailure('The terminal answered a snapshot oddly.'),
        );
      case Err(:final failure):
        return Err(failure);
    }
  }

  /// Gives the shown terminal the keyboard, or takes it away.
  Future<Result<void>> focus({required bool focused}) async =>
      _done(await _request('terminal.focus', {'focused': focused}));

  /// Ctrl and Alt as latched on the extra-keys row.
  Future<Result<void>> setModifiers({
    required bool ctrl,
    required bool alt,
  }) async =>
      _done(await _request('terminal.modifiers', {'ctrl': ctrl, 'alt': alt}));

  // ----------------------------------------------------------- measurement

  /// The renderer the page's terminals draw with (Phase 5 W6): `dom`, or
  /// `webgl`, which the page leaves for the DOM's when WebGL can't draw.
  /// Kept with the appearance for restarts.
  Future<Result<void>> setRenderer(String renderer) async {
    _configuration = {...?_configuration, 'renderer': renderer};
    if (!isReady) {
      return const Ok(null);
    }
    return _done(await _request('terminal.configure', {'renderer': renderer}));
  }

  /// Measurement (Phase 5 W6, the page's probe.ts): the page types [count]
  /// characters into [sessionId] as an input method's commit reaches it,
  /// [gapMs] apart, each timed from its input to the end of the frame that
  /// draws its echo, and erased again. Answers once the probe has started;
  /// [readProbe] has its figures.
  Future<Result<void>> startEchoProbe(
    int sessionId, {
    int count = 100,
    int gapMs = 50,
  }) async => _done(
    await _request('probe.echo', {
      'sessionId': sessionId,
      'count': count,
      'gapMs': gapMs,
    }),
  );

  /// Measurement: the page counts, hashes and times what [sessionId] writes
  /// between the marks [begin] and [end], and its frames meanwhile.
  Future<Result<void>> startFloodProbe(
    int sessionId, {
    required String begin,
    required String end,
  }) async => _done(
    await _request('probe.flood', {
      'sessionId': sessionId,
      'begin': begin,
      'end': end,
    }),
  );

  /// The probe's report, as the page sent it (probe.ts's ProbeReport:
  /// `state`, `kind`, `renderers`, and `echo` or `flood` once it has them).
  Future<Result<Map<String, Object?>>> readProbe() async {
    final result = await _request('probe.read', const <String, Object?>{});
    return switch (result) {
      Ok(:final value) when value is Map<String, Object?> => Ok(value),
      Ok() => const Err(BridgeFailure('The terminal answered a probe oddly.')),
      Err(:final failure) => Err(failure),
    };
  }

  Future<Result<Object?>> _request(String type, Map<String, Object?> payload) {
    if (_disposed) {
      return Future.value(const Err(BridgeFailure('The terminal is closed.')));
    }
    if (!isReady) {
      return Future.value(
        const Err(BridgeFailure('The terminal page is not ready.')),
      );
    }
    _nextId += 1;
    final id = 'h$_nextId';
    final encoded = BridgeMessage(
      id: id,
      type: type,
      payload: payload,
    ).encode();
    assert(
      parseTerminalMessage(encoded, TerminalDirection.hostToTerminal)
          is ParsedMessage,
      'the host built a $type message the protocol rejects',
    );
    final completer = Completer<Result<Object?>>();
    _pending[id] = _Pending(
      type,
      completer,
      Timer(requestTimeout, () => _timeOut(id)),
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
              '${pending.type} could not reach the terminal.',
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

  static Result<void> _done(Result<Object?> result) => switch (result) {
    Ok<Object?>() => const Ok(null),
    Err<Object?>(:final failure) => Err(failure),
  };

  static Result<({int columns, int rows})> _size(Object? value) {
    if (value is Map<String, Object?> &&
        value['cols'] is num &&
        value['rows'] is num) {
      return Ok((columns: value.integer('cols'), rows: value.integer('rows')));
    }
    return const Err(BridgeFailure('The terminal answered open oddly.'));
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
    switch (parseTerminalMessage(raw, TerminalDirection.terminalToHost)) {
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
      case 'terminal.ready':
        _onReady(payload);
      case 'terminal.focus':
        _emit(TerminalFocusChanged(focused: payload.flag('focused')));
      case 'terminal.modifiers':
        _emit(
          TerminalModifiersChanged(
            ctrl: payload.flag('ctrl'),
            alt: payload.flag('alt'),
          ),
        );
      case 'terminal.log':
        appLogger.log(
          LogLevel.values.byName(payload.string('level')),
          'terminal.page',
          'log',
          fields: {'message': _clip(payload.string('message'))},
        );
      case 'session.input':
        _emit(
          TerminalInput(
            payload.integer('sessionId'),
            payload.string('data'),
            binary: payload['binary'] == true,
          ),
        );
      case 'session.resized':
        _emit(
          TerminalResized(
            payload.integer('sessionId'),
            columns: payload.integer('cols'),
            rows: payload.integer('rows'),
          ),
        );
      case 'session.ack':
        _emit(
          TerminalAcknowledged(
            payload.integer('sessionId'),
            payload.integer('seq'),
          ),
        );
      case 'session.title':
        _emit(
          TerminalTitled(payload.integer('sessionId'), payload.string('title')),
        );
      case 'session.bell':
        _emit(TerminalBell(payload.integer('sessionId')));
      case 'session.link':
        _emit(
          TerminalLinkTapped(
            payload.integer('sessionId'),
            payload.string('text'),
          ),
        );
      case 'session.selection':
        _emit(
          TerminalSelectionChanged(
            payload.integer('sessionId'),
            active: payload.flag('active'),
          ),
        );
    }
  }

  void _onResponse(Map<String, Object?> payload) {
    final re = payload.string('re');
    final pending = _pending.remove(re);
    if (pending == null) {
      // A write the page refused answers with an error and nothing waits.
      if (!payload.flag('ok')) {
        final error = payload.object('error');
        appLogger.warn(
          _tag,
          'write_refused',
          fields: {'code': error.string('code'), 're': re},
        );
      }
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
    if (protocol != terminalProtocolVersion) {
      _fail(
        'page_protocol_mismatch',
        'The terminal speaks protocol $protocol; this app needs '
            '$terminalProtocolVersion.',
      );
      return;
    }
    _readyTimer?.cancel();
    _readyTimer = null;
    _pageStarts += 1;
    if (_pageStarts > 1) {
      appLogger.warn(_tag, 'page_restarted', fields: {'starts': _pageStarts});
      _failPending('The terminal page restarted.');
    }
    final engineVersion = payload.string('engineVersion');
    appLogger.info(_tag, 'page_ready', fields: {'version': engineVersion});
    _setStatus(
      TerminalViewStatus(TerminalViewPhase.ready, engineVersion: engineVersion),
    );
    final configuration = _configuration;
    if (configuration != null) {
      unawaited(_request('terminal.configure', configuration));
    }
    _emit(TerminalPageStarted(_pageStarts));
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
          'terminal.console',
          level,
          fields: {'message': _clip(message)},
        );
    }
  }

  // --------------------------------------------------------------- helpers

  void _armReadyTimer() {
    _readyTimer?.cancel();
    _readyTimer = Timer(readyTimeout, () {
      if (_status.phase == TerminalViewPhase.loading) {
        _fail(
          'ready_timeout',
          'The terminal did not start within ${readyTimeout.inSeconds} s.',
        );
      }
    });
  }

  void _fail(String event, String message) {
    appLogger.error(_tag, event, fields: {'message': message});
    _readyTimer?.cancel();
    _readyTimer = null;
    _failPending(message);
    _setStatus(TerminalViewStatus(TerminalViewPhase.failed, message: message));
  }

  void _setStatus(TerminalViewStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  void _emit(TerminalViewEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  /// Log lines stay short; page output can be arbitrarily long.
  static String _clip(String text) =>
      text.length <= 300 ? text : '${text.substring(0, 300)}…';
}
