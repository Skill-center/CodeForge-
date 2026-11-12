/// The saved text's digest off the UI isolate (Phase 3 W6, an owner item of
/// 2026-11-11): the same digest, and an event loop that keeps turning while
/// a 10 MiB text is digested. Frames come from the UI isolate's event loop:
/// while it turns, they keep coming.
library;

import 'dart:async';

import 'package:codeforge/core/editor/journal.dart';
import 'package:flutter_test/flutter_test.dart';

/// How long this isolate's event loop went without turning while [work]
/// ran: the longest gap between ticks of a 4 ms timer, and the ticks.
Future<({Duration longestGap, int ticks, Duration took})> _loopWhile(
  Future<void> Function() work,
) async {
  final watch = Stopwatch()..start();
  var last = watch.elapsed;
  var longest = Duration.zero;
  var ticks = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
    final now = watch.elapsed;
    if (now - last > longest) {
      longest = now - last;
    }
    last = now;
    ticks++;
  });
  // A turn of the loop before the work starts, so the first gap is fair.
  await Future<void>.delayed(const Duration(milliseconds: 20));
  last = watch.elapsed;
  longest = Duration.zero;
  ticks = 0;
  final start = watch.elapsed;
  await work();
  final took = watch.elapsed - start;
  // The gap the work left, if no tick came since.
  if (watch.elapsed - last > longest) {
    longest = watch.elapsed - last;
  }
  timer.cancel();
  return (longestGap: longest, ticks: ticks, took: took);
}

void main() {
  test('digestText gives textDigest, short and long, in any script', () async {
    const short = 'let a = 1;\n';
    final long = 'é€ ascii and more 😀\n' * 5000;
    expect(long.length, greaterThan(backgroundDigestChars));
    expect(await digestText(short), textDigest(short));
    expect(await digestText(long), textDigest(long));
    expect(await digestText(''), textDigest(''));
    expect(await digestTextInline(long), textDigest(long));
  });

  test('a 10 MiB digest leaves the event loop turning', () async {
    final text = 'abcdefghi\n' * (1024 * 1024);
    expect(text.length, 10 * 1024 * 1024);
    final expected = textDigest(text);

    // On this isolate, as before W6: the loop stops for the whole digest.
    late final String inline;
    final before = await _loopWhile(() async {
      inline = await digestTextInline(text);
    });
    // On a background isolate (digestText).
    late final String background;
    final after = await _loopWhile(() async {
      background = await digestText(text);
    });

    final report =
        'inline: ${before.took.inMilliseconds} ms, longest gap '
        '${before.longestGap.inMilliseconds} ms, ${before.ticks} ticks; '
        'background: ${after.took.inMilliseconds} ms, longest gap '
        '${after.longestGap.inMilliseconds} ms, ${after.ticks} ticks';
    // The figures, in the test output.
    // ignore: avoid_print
    print('text digest, 10 MiB: $report');
    expect(inline, expected);
    expect(background, expected);
    expect(
      after.longestGap,
      lessThan(const Duration(milliseconds: 100)),
      reason: report,
    );
    expect(after.longestGap, lessThan(before.longestGap), reason: report);
    expect(after.ticks, greaterThan(0), reason: report);
  });
}
