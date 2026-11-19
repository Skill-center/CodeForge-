/// The terminal panel's sessions and tabs (Phase 5 W3;
/// docs/TERMINAL_ARCHITECTURE.md §3). It pairs the TerminalService (the
/// host's sessions, through Pigeon) with the terminal page
/// ([TerminalView], xterm.js):
///   - each session's output is decoded as UTF-8 and written to its view in
///     order; when xterm.js has parsed a write, the session is credited with
///     the bytes behind it, so a flood waits in the kernel, never in the app;
///   - what the page types goes to the session, as bytes;
///   - the panel's size, set by the page, becomes the session's;
///   - after the page restarts, every view is opened again and refilled
///     from its session's buffer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/files/workspace_location.dart';
import '../../core/logging/logger.dart';
import '../../core/terminal/terminal_models.dart';
import '../../services/contracts.dart';
import '../providers.dart';
import 'terminal_providers.dart';
import 'terminal_view.dart';

const String _tag = 'terminal';

/// As many sessions as the host runs at once.
const int maxTerminalSessions = 8;

/// The most input sent to a session in one call.
const int _inputChunkBytes = 64 * 1024;

/// The most replayed output written to the page in one message.
const int _replayChunkBytes = 192 * 1024;

/// One tab of the terminal panel: a session, running or ended.
final class TerminalTab {
  const TerminalTab({
    required this.sessionId,
    required this.name,
    this.customName,
    this.title,
    this.state = TerminalSessionState.starting,
    this.exitCode,
    this.signal,
    this.problem,
    this.bell = false,
  });

  final int sessionId;

  /// Its own name, `Terminal N`.
  final String name;

  /// What the user renamed it to, if they did.
  final String? customName;

  /// The program's title for its window (`ESC ] 0 ;`), when it set one.
  final String? title;

  final TerminalSessionState state;
  final int? exitCode;
  final int? signal;
  final TerminalProblem? problem;

  /// A bell rang in it while another tab was shown.
  final bool bell;

  /// What the tab says.
  String get label => customName ?? name;

  bool get running => state != TerminalSessionState.exited;

  /// How the session ended, for its tab and its banner; null while it runs.
  String? get ending {
    if (running) {
      return null;
    }
    if (exitCode != null) {
      return 'exited with code $exitCode';
    }
    if (signal != null) {
      return 'ended by signal $signal';
    }
    return problem == TerminalProblem.lost ? 'connection lost' : 'ended';
  }

  static const Object _keep = Object();

  TerminalTab copyWith({
    Object? customName = _keep,
    String? title,
    TerminalSessionState? state,
    int? exitCode,
    int? signal,
    TerminalProblem? problem,
    bool? bell,
  }) {
    return TerminalTab(
      sessionId: sessionId,
      name: name,
      customName: identical(customName, _keep)
          ? this.customName
          : customName as String?,
      title: title ?? this.title,
      state: state ?? this.state,
      exitCode: exitCode ?? this.exitCode,
      signal: signal ?? this.signal,
      problem: problem ?? this.problem,
      bell: bell ?? this.bell,
    );
  }
}

/// What the terminal panel shows.
final class TerminalPanelState {
  const TerminalPanelState({
    required this.availability,
    this.unavailableReason = '',
    this.tabs = const [],
    this.activeId,
    this.starting = false,
    this.message,
    this.selection = false,
    this.focused = false,
    this.ctrl = false,
    this.alt = false,
    this.viewPhase = TerminalViewPhase.idle,
    this.viewMessage,
  });

  final TerminalAvailability availability;
  final String unavailableReason;
  final List<TerminalTab> tabs;

  /// The session shown, if any.
  final int? activeId;

  /// A session is starting.
  final bool starting;

  /// The last thing that went wrong, for the panel to say.
  final String? message;

  /// The shown session has a selection: Copy is offered.
  final bool selection;

  /// The page's terminal has the keyboard.
  final bool focused;

  /// Ctrl and Alt latched on the extra-keys row, for the next key.
  final bool ctrl;
  final bool alt;

  /// Where the terminal page is: loading, ready, or failed.
  final TerminalViewPhase viewPhase;
  final String? viewMessage;

  bool get available => availability == TerminalAvailability.available;

  TerminalTab? get active {
    for (final tab in tabs) {
      if (tab.sessionId == activeId) {
        return tab;
      }
    }
    return null;
  }

  bool get canStart =>
      available && !starting && tabs.length < maxTerminalSessions;

  static const Object _keep = Object();

  TerminalPanelState copyWith({
    List<TerminalTab>? tabs,
    Object? activeId = _keep,
    bool? starting,
    Object? message = _keep,
    bool? selection,
    bool? focused,
    bool? ctrl,
    bool? alt,
    TerminalViewPhase? viewPhase,
    Object? viewMessage = _keep,
  }) {
    return TerminalPanelState(
      availability: availability,
      unavailableReason: unavailableReason,
      tabs: tabs ?? this.tabs,
      activeId: identical(activeId, _keep) ? this.activeId : activeId as int?,
      starting: starting ?? this.starting,
      message: identical(message, _keep) ? this.message : message as String?,
      selection: selection ?? this.selection,
      focused: focused ?? this.focused,
      ctrl: ctrl ?? this.ctrl,
      alt: alt ?? this.alt,
      viewPhase: viewPhase ?? this.viewPhase,
      viewMessage: identical(viewMessage, _keep)
          ? this.viewMessage
          : viewMessage as String?,
    );
  }
}

/// One session's way to its view.
final class _Pipe {
  /// Its view is open in the page; output waits in [queue] until then.
  bool open = false;
  final List<TerminalOutput> queue = [];

  /// The next write's sequence number, and each unacknowledged write's end
  /// in the session's byte stream.
  int nextSeq = 0;
  final Map<int, int> acks = {};

  final StringBuffer _decoded = StringBuffer();
  ByteConversionSink? _decoder;

  /// [bytes] as text. A UTF-8 sequence split across batches is held back
  /// until the rest arrives; malformed bytes become U+FFFD.
  String decode(Uint8List bytes) {
    (_decoder ??= const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(StringConversionSink.fromStringSink(_decoded)))
        .add(bytes);
    final text = _decoded.toString();
    _decoded.clear();
    return text;
  }

  /// Back to a fresh view: nothing open, nothing pending, a new decoder.
  void reset() {
    open = false;
    queue.clear();
    acks.clear();
    _decoder?.close();
    _decoder = null;
    _decoded.clear();
  }
}

final class TerminalController extends Notifier<TerminalPanelState> {
  late TerminalService _service;
  late TerminalView _view;
  final Map<int, _Pipe> _pipes = {};
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// The panel's size in cells, as the page last fitted a view to it: new
  /// sessions start at it.
  ({int columns, int rows}) _size = (columns: 80, rows: 24);

  @override
  TerminalPanelState build() {
    ref.keepAlive();
    _service = ref.watch(terminalServiceProvider);
    _view = ref.watch(terminalViewProvider);
    _pipes.clear();
    _subscriptions
      ..add(_service.output.listen(_onOutput))
      ..add(_service.changes.listen(_onChanged))
      ..add(_view.events.listen(_onViewEvent))
      ..add(_view.statusChanges.listen(_onViewStatus));
    ref.onDispose(() {
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
    });
    return TerminalPanelState(
      availability: _service.availability,
      unavailableReason: _service.unavailableReason,
      viewPhase: _view.status.phase,
      viewMessage: _view.status.message,
    );
  }

  // -------------------------------------------------------------- sessions

  /// Starts a session in the open project's folder (the runtime's home for
  /// a folder from shared storage) and shows it.
  Future<void> newSession() async {
    if (!state.canStart) {
      if (state.tabs.length >= maxTerminalSessions) {
        state = state.copyWith(
          message: 'Eight terminals are open: close one first.',
        );
      }
      return;
    }
    state = state.copyWith(starting: true, message: null);
    unawaited(_view.start());
    final workspace = ref.read(currentWorkspaceProvider);
    final label = 'Terminal ${_freeNumber()}';
    final started = await _service.start(
      TerminalSpec(
        project: workspace is ProjectLocation ? workspace.folder : null,
        rows: _size.rows,
        columns: _size.columns,
        label: label,
      ),
    );
    switch (started) {
      case Err(:final failure):
        appLogger.warn(_tag, 'start_failed', fields: {'error': failure.message});
        state = state.copyWith(starting: false, message: failure.message);
      case Ok(:final value):
        _pipes.putIfAbsent(value.id, _Pipe.new);
        final tab = _tabFrom(value, name: label);
        state = state.copyWith(
          starting: false,
          tabs: [...state.tabs, tab],
          activeId: value.id,
          selection: false,
        );
        await _openView(value.id, activate: true);
    }
  }

  /// Shows session [id].
  void activate(int id) {
    if (!state.tabs.any((tab) => tab.sessionId == id)) {
      return;
    }
    state = state.copyWith(
      activeId: id,
      selection: false,
      tabs: [
        for (final tab in state.tabs)
          tab.sessionId == id && tab.bell ? tab.copyWith(bell: false) : tab,
      ],
    );
    if (_pipes[id]?.open ?? false) {
      unawaited(_view.activate(id));
    }
  }

  /// The tab after (or before, [step] -1) the shown one, wrapping around:
  /// a swipe across the tabs.
  void step(int step) {
    final tabs = state.tabs;
    if (tabs.length < 2) {
      return;
    }
    final index = tabs.indexWhere((tab) => tab.sessionId == state.activeId);
    final next = (index + step) % tabs.length;
    activate(tabs[next < 0 ? next + tabs.length : next].sessionId);
  }

  /// Closes tab [id]: a running session is ended with everything it started
  /// (the panel asks first). Its tab goes at once; the host forgets it once
  /// it has ended.
  Future<void> close(int id) async {
    final index = state.tabs.indexWhere((tab) => tab.sessionId == id);
    if (index < 0) {
      return;
    }
    final tab = state.tabs[index];
    final tabs = [...state.tabs]..removeAt(index);
    var activeId = state.activeId;
    if (activeId == id) {
      activeId = tabs.isEmpty
          ? null
          : tabs[index < tabs.length ? index : tabs.length - 1].sessionId;
    }
    state = state.copyWith(
      tabs: tabs,
      activeId: activeId,
      selection: activeId == state.activeId ? state.selection : false,
    );
    final next = activeId;
    if (next != null && next != id) {
      activate(next);
    }
    final pipe = _pipes.remove(id);
    if (pipe != null && pipe.open) {
      unawaited(_view.close(id));
    }
    if (tab.running) {
      final ended = await _service.end(id);
      if (ended case Err(:final failure)) {
        appLogger.warn(_tag, 'end_failed', fields: {'error': failure.message});
      }
    }
    await _forget(id);
  }

  /// Names tab [id]; an empty name gives it back its own.
  void rename(int id, String name) {
    final trimmed = name.trim();
    _updateTab(
      id,
      (tab) => tab.copyWith(customName: trimmed.isEmpty ? null : trimmed),
    );
  }

  /// The user's End all: every session ends with what it started.
  Future<void> endAll() async {
    final ended = await _service.endAll();
    if (ended case Err(:final failure)) {
      state = state.copyWith(message: failure.message);
    }
  }

  void dismissMessage() => state = state.copyWith(message: null);

  /// Loads the page again after it failed to start.
  Future<void> retryPage() => _view.reloadPage();

  // ---------------------------------------------------- keys and clipboard

  /// An extra key for the shown session, with the latched Ctrl and Alt,
  /// which it releases.
  Future<void> sendKey(String key) async {
    final id = state.activeId;
    if (id == null || !(state.active?.running ?? false)) {
      return;
    }
    final ctrl = state.ctrl;
    final alt = state.alt;
    if (ctrl || alt) {
      state = state.copyWith(ctrl: false, alt: false);
      unawaited(_view.setModifiers(ctrl: false, alt: false));
    }
    final sent = await _view.key(id, key, ctrl: ctrl, alt: alt);
    if (sent case Err(:final failure)) {
      appLogger.warn(_tag, 'key_failed', fields: {'error': failure.message});
    }
  }

  /// Latches Ctrl for the next key, or releases it.
  void toggleCtrl() => _latch(ctrl: !state.ctrl, alt: state.alt);

  /// Latches Alt for the next key, or releases it.
  void toggleAlt() => _latch(ctrl: state.ctrl, alt: !state.alt);

  void _latch({required bool ctrl, required bool alt}) {
    state = state.copyWith(ctrl: ctrl, alt: alt);
    unawaited(_view.setModifiers(ctrl: ctrl, alt: alt));
  }

  /// Pastes the clipboard's text into the shown session; the page drops
  /// control characters and honours bracketed paste.
  Future<void> paste() async {
    final id = state.activeId;
    if (id == null) {
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      return;
    }
    final pasted = await _view.paste(id, text);
    if (pasted case Err(:final failure)) {
      state = state.copyWith(message: failure.message);
    }
  }

  /// Copies the shown session's selection to the clipboard, then drops it.
  Future<void> copy() async {
    final id = state.activeId;
    if (id == null) {
      return;
    }
    final copied = await _view.copy(id);
    switch (copied) {
      case Ok(:final value) when value.isNotEmpty:
        await Clipboard.setData(ClipboardData(text: value));
        unawaited(_view.select(id, all: false));
      case Ok():
        break;
      case Err(:final failure):
        state = state.copyWith(message: failure.message);
    }
  }

  Future<void> selectAll() async {
    final id = state.activeId;
    if (id != null) {
      await _view.select(id, all: true);
    }
  }

  /// Clears the shown session's scrollback.
  Future<void> clear() async {
    final id = state.activeId;
    if (id != null) {
      await _view.clear(id);
    }
  }

  /// Gives the shown terminal the keyboard, or takes it away.
  Future<void> focus({bool focused = true}) =>
      _view.focus(focused: focused).then((_) {});

  /// The page's appearance (theme, font size), as the pane derives it.
  Future<void> configure(Map<String, Object?> configuration) =>
      _view.configure(configuration).then((_) {});

  // -------------------------------------------------------------- the view

  /// Opens session [id]'s view once the page is ready, sizes the session to
  /// it, and writes what arrived meanwhile, or, after a page restart
  /// ([replay]), the session's buffer.
  Future<void> _openView(
    int id, {
    required bool activate,
    bool replay = false,
  }) async {
    final pipe = _pipes[id];
    if (pipe == null || pipe.open || !await _pageReady()) {
      return;
    }
    final opened = await _view.open(id, activate: activate);
    if (!identical(_pipes[id], pipe)) {
      return; // closed meanwhile
    }
    switch (opened) {
      case Err(:final failure):
        appLogger.warn(_tag, 'view_failed', fields: {'error': failure.message});
        return;
      case Ok(:final value):
        pipe.open = true;
        _size = value;
        unawaited(
          _service.resize(id, rows: value.rows, columns: value.columns),
        );
    }
    var from = 0;
    if (replay) {
      final attached = await _service.attach(id);
      if (attached case Ok(:final value)) {
        _writeReplay(id, pipe, value);
        from = value.end;
      }
    }
    final queued = [...pipe.queue];
    pipe.queue.clear();
    for (final output in queued) {
      if (output.end <= from) {
        continue;
      }
      final skip = from > output.offset ? from - output.offset : 0;
      _send(
        id,
        pipe,
        skip == 0 ? output.bytes : Uint8List.sublistView(output.bytes, skip),
        output.end,
      );
    }
  }

  void _writeReplay(int id, _Pipe pipe, TerminalReplay replay) {
    final bytes = replay.bytes;
    for (var start = 0; start < bytes.length; start += _replayChunkBytes) {
      final end = start + _replayChunkBytes < bytes.length
          ? start + _replayChunkBytes
          : bytes.length;
      _send(
        id,
        pipe,
        Uint8List.sublistView(bytes, start, end),
        replay.offset + end,
      );
    }
  }

  /// Waits for the page: true once it is ready, false if it failed or never
  /// answered.
  Future<bool> _pageReady() async {
    if (_view.isReady) {
      return true;
    }
    final settled = _view.statusChanges
        .firstWhere(
          (status) =>
              status.phase == TerminalViewPhase.ready ||
              status.phase == TerminalViewPhase.failed,
        )
        .timeout(const Duration(seconds: 30));
    unawaited(_view.start());
    try {
      return (await settled).phase == TerminalViewPhase.ready;
    } on Object {
      return _view.isReady;
    }
  }

  void _onOutput(TerminalOutput output) {
    // Output can arrive before the start that made it returns: it waits.
    final pipe = _pipes.putIfAbsent(output.sessionId, _Pipe.new);
    if (!pipe.open) {
      pipe.queue.add(output);
      return;
    }
    _send(output.sessionId, pipe, output.bytes, output.end);
  }

  void _send(int id, _Pipe pipe, Uint8List bytes, int end) {
    final seq = pipe.nextSeq++;
    pipe.acks[seq] = end;
    if (!_view.write(id, seq, pipe.decode(bytes))) {
      // The page went away: its restart refills the view from the buffer.
      pipe.acks.remove(seq);
    }
  }

  void _onViewEvent(TerminalViewEvent event) {
    switch (event) {
      case TerminalPageStarted(:final starts):
        if (starts > 1) {
          _reopenAll();
        }
      case TerminalInput(:final sessionId, :final data, :final binary):
        unawaited(_input(sessionId, data, binary: binary));
      case TerminalResized(:final sessionId, :final columns, :final rows):
        _size = (columns: columns, rows: rows);
        unawaited(_service.resize(sessionId, rows: rows, columns: columns));
      case TerminalAcknowledged(:final sessionId, :final seq):
        final end = _pipes[sessionId]?.acks.remove(seq);
        if (end != null) {
          unawaited(_service.acknowledge(sessionId, end));
        }
      case TerminalTitled(:final sessionId, :final title):
        _updateTab(sessionId, (tab) => tab.copyWith(title: title));
      case TerminalBell(:final sessionId):
        if (sessionId != state.activeId) {
          _updateTab(sessionId, (tab) => tab.copyWith(bell: true));
        }
      case TerminalLinkTapped(:final sessionId):
        appLogger.debug(_tag, 'link', fields: {'session': sessionId});
      case TerminalSelectionChanged(:final sessionId, :final active):
        if (sessionId == state.activeId) {
          state = state.copyWith(selection: active);
        }
      case TerminalFocusChanged(:final focused):
        state = state.copyWith(focused: focused);
      case TerminalModifiersChanged(:final ctrl, :final alt):
        state = state.copyWith(ctrl: ctrl, alt: alt);
    }
  }

  void _onViewStatus(TerminalViewStatus status) {
    state = state.copyWith(
      viewPhase: status.phase,
      viewMessage: status.message,
    );
  }

  /// The page restarted: every view is opened again and refilled from its
  /// session's buffer.
  void _reopenAll() {
    for (final tab in state.tabs) {
      final pipe = _pipes[tab.sessionId];
      if (pipe == null) {
        continue;
      }
      pipe.reset();
      unawaited(
        _openView(
          tab.sessionId,
          activate: tab.sessionId == state.activeId,
          replay: true,
        ),
      );
    }
  }

  Future<void> _input(int id, String data, {required bool binary}) async {
    final bytes = binary
        ? Uint8List.fromList([for (final unit in data.codeUnits) unit & 0xFF])
        : utf8.encode(data);
    for (var start = 0; start < bytes.length; start += _inputChunkBytes) {
      final end = start + _inputChunkBytes < bytes.length
          ? start + _inputChunkBytes
          : bytes.length;
      final written = await _service.write(
        id,
        Uint8List.sublistView(bytes, start, end),
      );
      if (written case Err(:final failure)) {
        appLogger.warn(
          _tag,
          'input_failed',
          fields: {'error': failure.message},
        );
        if (failure is TerminalFailure &&
            failure.problem == TerminalProblem.inputFull) {
          state = state.copyWith(message: failure.message);
        }
        return;
      }
    }
  }

  void _onChanged(TerminalInfo info) {
    _updateTab(
      info.id,
      (tab) => TerminalTab(
        sessionId: tab.sessionId,
        name: tab.name,
        customName: tab.customName,
        title: tab.title,
        state: info.state,
        exitCode: info.exitCode,
        signal: info.signal,
        problem: info.problem,
        bell: tab.bell,
      ),
    );
  }

  // --------------------------------------------------------------- helpers

  void _updateTab(int id, TerminalTab Function(TerminalTab tab) change) {
    if (!state.tabs.any((tab) => tab.sessionId == id)) {
      return;
    }
    state = state.copyWith(
      tabs: [
        for (final tab in state.tabs) tab.sessionId == id ? change(tab) : tab,
      ],
    );
  }

  /// The host forgets an ended session; one still ending is asked again.
  Future<void> _forget(int id) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final removed = await _service.remove(id);
      if (removed case Err(
        :final failure,
      ) when failure is TerminalFailure &&
          failure.problem == TerminalProblem.stillRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        continue;
      }
      return;
    }
  }

  TerminalTab _tabFrom(TerminalInfo info, {required String name}) {
    return TerminalTab(
      sessionId: info.id,
      name: name,
      state: info.state,
      exitCode: info.exitCode,
      signal: info.signal,
      problem: info.problem,
    );
  }

  /// The lowest number no open tab's `Terminal N` uses.
  int _freeNumber() {
    final taken = {for (final tab in state.tabs) tab.name};
    var number = 1;
    while (taken.contains('Terminal $number')) {
      number++;
    }
    return number;
  }
}

final terminalControllerProvider =
    NotifierProvider<TerminalController, TerminalPanelState>(
      TerminalController.new,
    );
