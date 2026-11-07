/// The hot-exit journal's records and their replay (ADR-0008,
/// docs/EDITOR_ARCHITECTURE.md §7).
///
/// A dirty document's journal is a snapshot (its whole text at one
/// version) followed by the change sets the editor sent after it, in the
/// order they arrived. Replaying applies each change on top of the snapshot
/// and gives back exactly the text the editor had: test/core/journal_test.dart
/// holds it to that for random edit sequences cut at random snapshot points.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'change_set.dart';

/// One batch of edits as the editor sent it (`doc.changed`): the change set
/// that turns the text at [baseVersion] into the text at [version].
final class JournalChange {
  const JournalChange({
    required this.baseVersion,
    required this.version,
    required this.lengthBefore,
    required this.lengthAfter,
    required this.changes,
  });

  final int baseVersion;
  final int version;

  /// Text lengths (UTF-16 code units) before and after, checked on replay.
  final int lengthBefore;
  final int lengthAfter;

  /// CodeMirror change-set JSON (core/editor/change_set.dart).
  final List<Object?> changes;

  /// [changes] as stored: JSON text.
  String encodeChanges() => jsonEncode(changes);

  /// Stored change-set JSON back as a list; null when it is not one.
  static List<Object?>? decodeChanges(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is List<Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

/// What replaying a journal gave back.
final class JournalReplay {
  const JournalReplay({
    required this.text,
    required this.version,
    required this.applied,
    this.problem,
  });

  /// The text after every change that fitted.
  final String text;

  /// The version of [text].
  final int version;

  /// Changes applied on top of the snapshot.
  final int applied;

  /// Why replay stopped before the last change, or null when it used them
  /// all.
  final String? problem;
}

/// Replays [changes], in the order they were recorded, on top of a snapshot
/// of [text] at [version].
///
/// Changes the snapshot already contains (version at or below it) are
/// skipped, so a crash between writing a snapshot and dropping the changes
/// it covers costs nothing. Replay stops at the first change that does not
/// continue the text (a gap in the versions, a length that does not match,
/// a change set that does not fit) and keeps everything before it: damage at
/// the tail never loses the rest.
JournalReplay replayJournal({
  required String text,
  required int version,
  required Iterable<JournalChange> changes,
}) {
  var current = text;
  var at = version;
  var applied = 0;
  JournalReplay stop(String problem) => JournalReplay(
    text: current,
    version: at,
    applied: applied,
    problem: problem,
  );
  for (final change in changes) {
    if (change.version <= at) {
      continue;
    }
    if (change.baseVersion != at) {
      return stop(
        'version gap: the next change starts from ${change.baseVersion}, '
        'the text is at $at',
      );
    }
    if (change.lengthBefore != current.length) {
      return stop(
        'change ${change.version} expects ${change.lengthBefore} '
        'characters, the text has ${current.length}',
      );
    }
    final String next;
    try {
      next = applyChanges(current, change.changes);
    } on ChangeApplyException catch (error) {
      return stop('change ${change.version}: ${error.message}');
    }
    if (next.length != change.lengthAfter) {
      return stop(
        'change ${change.version} should leave ${change.lengthAfter} '
        'characters, it left ${next.length}',
      );
    }
    current = next;
    at = change.version;
    applied += 1;
  }
  return JournalReplay(text: current, version: at, applied: applied);
}

/// SHA-256 of [text]'s UTF-8 bytes, in hex: how a journal recognises the
/// saved text it was written against.
String textDigest(String text) => sha256.convert(utf8.encode(text)).toString();
