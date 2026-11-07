/// The hot-exit journal's replay (core/editor/journal.dart, Phase 2 W5):
/// a snapshot plus the changes after it replays to the live text for
/// randomized edit sequences (G4), and damage stops replay without losing
/// what came before it.
library;

import 'dart:math';

import 'package:codeforge/core/editor/change_set.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/random_edits.dart';

/// Records [sets] applied in turn to [text] at [version]: the journal's
/// changes, and the text at every version.
(List<JournalChange>, Map<int, String>) _record(
  String text,
  int version,
  List<List<Object?>> sets,
) {
  final log = <JournalChange>[];
  final texts = {version: text};
  var live = text;
  var at = version;
  for (final changes in sets) {
    final lengths = changeLengths(changes);
    final next = applyChanges(live, changes);
    log.add(
      JournalChange(
        baseVersion: at,
        version: at + 1,
        lengthBefore: lengths.before,
        lengthAfter: lengths.after,
        changes: changes,
      ),
    );
    live = next;
    at += 1;
    texts[at] = live;
  }
  return (log, texts);
}

JournalChange _with(
  JournalChange change, {
  int? baseVersion,
  int? lengthBefore,
  int? lengthAfter,
  List<Object?>? changes,
}) {
  return JournalChange(
    baseVersion: baseVersion ?? change.baseVersion,
    version: change.version,
    lengthBefore: lengthBefore ?? change.lengthBefore,
    lengthAfter: lengthAfter ?? change.lengthAfter,
    changes: changes ?? change.changes,
  );
}

void main() {
  group('replay', () {
    test('equals the live text for randomized edit sequences (G4)', () {
      for (var seed = 0; seed < 400; seed++) {
        final random = Random(seed);
        final initial = randomText(random, 40);
        var live = initial;
        final start = random.nextInt(5);
        final sets = <List<Object?>>[];
        for (var i = 0, n = 1 + random.nextInt(60); i < n; i++) {
          final changes = randomChanges(random, live);
          sets.add(changes);
          live = applyChanges(live, changes);
        }
        final (log, texts) = _record(initial, start, sets);
        final end = start + sets.length;
        expect(texts[end], live, reason: 'seed $seed');

        // A snapshot at any version, then the whole log: the store keeps
        // changes a snapshot covers until it lands, and replay skips them.
        final at = texts.keys.elementAt(random.nextInt(texts.length));
        final replay = replayJournal(
          text: texts[at]!,
          version: at,
          changes: log,
        );
        expect(replay.problem, isNull, reason: 'seed $seed');
        expect(replay.text, live, reason: 'seed $seed');
        expect(replay.version, end, reason: 'seed $seed');
        expect(replay.applied, end - at, reason: 'seed $seed');

        // The same after the round trip through the store's JSON.
        final stored = [
          for (final change in log)
            _with(
              change,
              changes: JournalChange.decodeChanges(change.encodeChanges())!,
            ),
        ];
        expect(
          replayJournal(text: texts[at]!, version: at, changes: stored).text,
          live,
          reason: 'seed $seed',
        );
      }
    });

    final (log, texts) = _record('abc', 0, [
      [
        3,
        [0, 'd'],
      ],
      [
        [1],
        3,
      ],
      [
        1,
        [2, 'X', 'Y'],
      ],
    ]);

    test('applies every change after the snapshot', () {
      expect(texts[3], 'bX\nY');
      final replay = replayJournal(text: 'abc', version: 0, changes: log);
      expect(replay.text, 'bX\nY');
      expect(replay.version, 3);
      expect(replay.applied, 3);
      expect(replay.problem, isNull);
    });

    test('a snapshot newer than every change needs none of them', () {
      final replay = replayJournal(text: 'bX\nY', version: 3, changes: log);
      expect(replay.text, 'bX\nY');
      expect(replay.applied, 0);
      expect(replay.problem, isNull);
    });

    test('a missing change stops replay at the gap, keeping the rest', () {
      final replay = replayJournal(
        text: 'abc',
        version: 0,
        changes: [log[0], log[2]],
      );
      expect(replay.text, 'abcd');
      expect(replay.version, 1);
      expect(replay.applied, 1);
      expect(replay.problem, contains('version gap'));
    });

    test('a change that does not fit the text stops replay before it', () {
      for (final damaged in [
        _with(log[1], lengthBefore: 7),
        _with(log[1], lengthAfter: 9),
        _with(log[1], changes: ['x']),
        _with(log[1], changes: [99]),
        _with(log[1], baseVersion: 0),
      ]) {
        final replay = replayJournal(
          text: 'abc',
          version: 0,
          changes: [log[0], damaged, log[2]],
        );
        expect(replay.text, 'abcd');
        expect(replay.version, 1);
        expect(replay.applied, 1);
        expect(replay.problem, isNotNull);
      }
    });
  });

  group('storage helpers', () {
    test('change sets survive JSON; anything else decodes to null', () {
      const change = JournalChange(
        baseVersion: 4,
        version: 5,
        lengthBefore: 3,
        lengthAfter: 4,
        changes: [
          1,
          [0, 'é', ''],
          2,
        ],
      );
      expect(JournalChange.decodeChanges(change.encodeChanges()), [
        1,
        [0, 'é', ''],
        2,
      ]);
      expect(JournalChange.decodeChanges('{"a": 1}'), isNull);
      expect(JournalChange.decodeChanges('[1, '), isNull);
    });

    test('textDigest is the SHA-256 of the UTF-8 text', () {
      expect(
        textDigest(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        textDigest('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(textDigest('é'), isNot(textDigest('e')));
    });
  });
}
