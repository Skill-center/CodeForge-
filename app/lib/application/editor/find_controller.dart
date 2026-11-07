/// The find bar's session (Phase 2 W6; docs/EDITOR_ARCHITECTURE.md §8).
///
/// The page holds the search itself: CodeMirror's query, the highlighted
/// matches, and the session that follows the user from tab to tab. This
/// controller opens it, feeds it the query and options, steps through the
/// matches, replaces, and closes it; the page reports counts back as
/// [SearchStateChanged] events.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import 'editor_host.dart';
import 'editor_providers.dart';

/// Selections longer than this do not seed the query.
const int maxSeedLength = 200;

/// What the find bar shows.
final class FindState {
  const FindState({
    this.open = false,
    this.replaceOpen = false,
    this.query = '',
    this.replacement = '',
    this.caseSensitive = false,
    this.wholeWord = false,
    this.regexp = false,
    this.valid = false,
    this.matches = 0,
    this.current = 0,
    this.capped = false,
    this.focusRequests = 0,
  });

  final bool open;
  final bool replaceOpen;
  final String query;
  final String replacement;
  final bool caseSensitive;
  final bool wholeWord;
  final bool regexp;

  /// False while the query is empty or a broken regular expression.
  final bool valid;

  /// The page's count; when [capped], at least this many.
  final int matches;

  /// The 1-based match the selection is on; 0 when it is on none.
  final int current;
  final bool capped;

  /// Bumped whenever the query field should take focus again.
  final int focusRequests;

  /// The count as the bar words it; empty while there is no query.
  String get summary {
    if (query.isEmpty) {
      return '';
    }
    if (!valid) {
      return regexp ? 'Invalid pattern' : '';
    }
    if (matches == 0) {
      return 'No results';
    }
    final total = capped ? '$matches+' : '$matches';
    if (current > 0) {
      return '$current of $total';
    }
    return matches == 1 && !capped ? '1 result' : '$total results';
  }

  FindState copyWith({
    bool? open,
    bool? replaceOpen,
    String? query,
    String? replacement,
    bool? caseSensitive,
    bool? wholeWord,
    bool? regexp,
    bool? valid,
    int? matches,
    int? current,
    bool? capped,
    int? focusRequests,
  }) => FindState(
    open: open ?? this.open,
    replaceOpen: replaceOpen ?? this.replaceOpen,
    query: query ?? this.query,
    replacement: replacement ?? this.replacement,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    wholeWord: wholeWord ?? this.wholeWord,
    regexp: regexp ?? this.regexp,
    valid: valid ?? this.valid,
    matches: matches ?? this.matches,
    current: current ?? this.current,
    capped: capped ?? this.capped,
    focusRequests: focusRequests ?? this.focusRequests,
  );

  /// Closed, keeping the query and options for next time.
  FindState closed() =>
      copyWith(open: false, matches: 0, current: 0, capped: false);
}

final class FindController extends Notifier<FindState> {
  /// `search.set` requests on their way; while any is, a report that the
  /// session closed is older than the query being sent and is ignored.
  int _pushing = 0;

  @override
  FindState build() {
    final host = ref.watch(editorHostProvider);
    final events = host.events.listen(_onEditorEvent);
    final status = host.statusChanges.listen(_onStatus);
    ref.onDispose(() {
      unawaited(events.cancel());
      unawaited(status.cancel());
    });
    return const FindState();
  }

  EditorHost get _host => ref.read(editorHostProvider);

  /// Opens the bar, or takes the user back to it. A short selection on one
  /// line becomes the query, as in desktop editors.
  Future<void> open({bool replace = false}) async {
    final seed = await _selectedText();
    state = state.copyWith(
      open: true,
      replaceOpen: replace || (state.open && state.replaceOpen),
      query: seed ?? state.query,
      focusRequests: state.focusRequests + 1,
    );
    await _push();
  }

  /// Closes the bar and ends the page's session. [refocusEditor] hands the
  /// keyboard back to the editor, for when the bar had it.
  Future<void> close({bool refocusEditor = false}) async {
    if (!state.open) {
      return;
    }
    state = state.closed();
    await _host.exec('closeSearch');
    if (refocusEditor) {
      await _host.exec('focus');
    }
  }

  void setQuery(String query) {
    if (query != state.query) {
      state = state.copyWith(query: query);
      unawaited(_push());
    }
  }

  void setReplacement(String replacement) {
    if (replacement != state.replacement) {
      state = state.copyWith(replacement: replacement);
      unawaited(_push());
    }
  }

  void toggleCaseSensitive() {
    state = state.copyWith(caseSensitive: !state.caseSensitive);
    unawaited(_push());
  }

  void toggleWholeWord() {
    state = state.copyWith(wholeWord: !state.wholeWord);
    unawaited(_push());
  }

  void toggleRegexp() {
    state = state.copyWith(regexp: !state.regexp);
    unawaited(_push());
  }

  void toggleReplace() {
    state = state.copyWith(replaceOpen: !state.replaceOpen);
  }

  Future<void> next() => _run('findNext');
  Future<void> previous() => _run('findPrevious');

  /// Replaces the match the selection is on and moves to the next; on the
  /// first press, when the selection is on none, just selects one.
  Future<void> replaceOne() => _run('replaceNext');
  Future<void> replaceAll() => _run('replaceAll');

  Future<void> _run(String command) async {
    if (state.open && state.valid) {
      await _host.exec(command);
    }
  }

  /// Sends the query and options to the page.
  Future<void> _push() async {
    if (!state.open) {
      return;
    }
    final sent = state;
    _pushing += 1;
    final Result<bool> result;
    try {
      result = await _host.search(
        sent.query,
        caseSensitive: sent.caseSensitive,
        wholeWord: sent.wholeWord,
        regexp: sent.regexp,
        replacement: sent.replacement,
      );
    } finally {
      _pushing -= 1;
    }
    // Only the newest query's answer counts.
    final valid = result.valueOrNull;
    if (valid != null && state.open && state.query == sent.query) {
      state = state.copyWith(valid: valid);
    }
  }

  /// The selected text, when it is short and on one line.
  Future<String?> _selectedText() async {
    final docId = _host.activeDocId;
    if (docId == null) {
      return null;
    }
    // The page reports the selection with pending edits.
    await _host.flush(docId);
    final text = _host.textOf(docId);
    final selection = _host.viewStateOf(docId)?.selection;
    if (text == null || selection == null) {
      return null;
    }
    final a = selection.anchor;
    final b = selection.head;
    final from = a < b ? a : b;
    final to = a < b ? b : a;
    if (from == to || to > text.length || to - from > maxSeedLength) {
      return null;
    }
    final selected = text.substring(from, to);
    if (selected.contains('\n')) {
      return null;
    }
    return state.regexp ? RegExp.escape(selected) : selected;
  }

  void _onEditorEvent(EditorHostEvent event) {
    if (event is! SearchStateChanged ||
        !state.open ||
        event.docId != _host.activeDocId) {
      return;
    }
    if (!event.open) {
      // Escape in the editor ended the session; the bar goes too.
      if (_pushing == 0) {
        state = state.closed();
      }
      return;
    }
    state = state.copyWith(
      valid: event.valid,
      matches: event.matches,
      current: event.current,
      capped: event.capped,
    );
  }

  /// A restarted page has lost the session; an open bar sends it again.
  void _onStatus(EditorHostStatus status) {
    if (status.phase == EditorHostPhase.ready && state.open) {
      unawaited(_push());
    }
  }
}

final findControllerProvider = NotifierProvider<FindController, FindState>(
  FindController.new,
);
