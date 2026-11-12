/// Fuzzy matching of workspace paths for Go to File (Phase 3 W4).
///
/// A query matches a path when its characters appear in the path in order,
/// ignoring case and the query's white space: `wbscr` finds
/// `lib/features/workbench/workbench_screen.dart`. A match scores higher
/// when its characters start words (after `/`, `_`, `-`, `.` or a space, or
/// at a lower-to-upper case change), run together, and lie in the file name
/// rather than its folders. The method is fzf's first one: the shortest
/// window of the path that holds the query, matched greedily.
library;

/// A path prepared for matching once, so that each keystroke only compares.
final class FuzzyTarget {
  FuzzyTarget(this.path)
    : lower = _lower(path),
      nameStart = path.lastIndexOf('/') + 1;

  final String path;

  /// [path] in lower case, index for index.
  final String lower;

  /// Where the file name starts in [path].
  final int nameStart;

  /// Whether a segment of [path] starts with a dot, as hidden files do.
  bool get hidden => path.startsWith('.') || path.contains('/.');
}

/// A path that matched: how well, and which of its characters matched.
final class PathMatch {
  const PathMatch(this.path, this.score, this.positions);

  final String path;

  /// Higher is better.
  final int score;

  /// The indices in [path] of the matched characters, ascending.
  final List<int> positions;
}

const int _match = 16;
const int _segmentStart = 10;
const int _wordStart = 8;
const int _camel = 7;
const int _consecutive = 4;
const int _gapStart = 3;
const int _gapExtension = 1;
const int _inName = 24;
const int _atNameStart = 8;

/// The query as matching uses it: lower case, without white space.
String normalizeQuery(String query) =>
    _lower(query).replaceAll(RegExp(r'\s+'), '');

/// Whether every character of [query] (normalized) appears in [target] in
/// order. Cheaper than scoring: one pass.
bool fuzzyContains(String query, FuzzyTarget target) {
  final lower = target.lower;
  var q = 0;
  for (var i = 0; i < lower.length && q < query.length; i++) {
    if (lower.codeUnitAt(i) == query.codeUnitAt(q)) {
      q++;
    }
  }
  return q == query.length;
}

/// Scores [target] against [query] (normalized); null when not every query
/// character appears in order. An empty query matches with score 0.
PathMatch? matchPath(String query, FuzzyTarget target) {
  final positions = <int>[];
  final score = _bestScore(query, target, positions);
  return score == null ? null : PathMatch(target.path, score, positions);
}

/// The best [limit] matches of [query] (normalized) among [targets]: by
/// score, then the shorter file name, then the shorter path, then the
/// path. An empty query keeps the first [limit] targets in order.
List<PathMatch> rankTargets(
  String query,
  Iterable<FuzzyTarget> targets, {
  int limit = 100,
}) {
  if (query.isEmpty) {
    return [
      for (final target in targets.take(limit))
        PathMatch(target.path, 0, const []),
    ];
  }
  final scored = <(FuzzyTarget, int)>[];
  for (final target in targets) {
    final score = _bestScore(query, target, null);
    if (score != null) {
      scored.add((target, score));
    }
  }
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    if (byScore != 0) {
      return byScore;
    }
    final (x, y) = (a.$1, b.$1);
    final byName = (x.path.length - x.nameStart).compareTo(
      y.path.length - y.nameStart,
    );
    if (byName != 0) {
      return byName;
    }
    final byLength = x.path.length.compareTo(y.path.length);
    return byLength != 0 ? byLength : x.path.compareTo(y.path);
  });
  return [
    for (final (target, _) in scored.take(limit)) matchPath(query, target)!,
  ];
}

/// The better of matching within the file name, with its bonus, and
/// matching across the whole path; fills [positions] for the one chosen.
int? _bestScore(String query, FuzzyTarget target, List<int>? positions) {
  if (query.isEmpty) {
    return 0;
  }
  final whole = _score(query, target, 0, null);
  if (whole == null) {
    return null;
  }
  var best = whole;
  var from = 0;
  final nameStart = target.nameStart;
  final name = _score(query, target, nameStart, null);
  if (name != null) {
    var inName = name + _inName;
    if (_windowStart(query, target.lower, nameStart) == nameStart) {
      inName += _atNameStart;
    }
    if (inName >= whole) {
      best = inName;
      from = nameStart;
    }
  }
  if (positions != null) {
    _score(query, target, from, positions);
  }
  return best;
}

/// Where the shortest window holding [query] in [lower] starts, searching
/// from [from]; null when there is none.
int? _windowStart(String query, String lower, int from) {
  var q = 0;
  var end = -1;
  for (var i = from; i < lower.length; i++) {
    if (lower.codeUnitAt(i) == query.codeUnitAt(q)) {
      q++;
      if (q == query.length) {
        end = i;
        break;
      }
    }
  }
  if (end < 0) {
    return null;
  }
  q = query.length - 1;
  for (var i = end; i >= from; i--) {
    if (lower.codeUnitAt(i) == query.codeUnitAt(q)) {
      q--;
      if (q < 0) {
        return i;
      }
    }
  }
  return null;
}

/// The score of the shortest window holding [query] in [target] from
/// [from], matched greedily; adds the matched indices to [positions].
int? _score(String query, FuzzyTarget target, int from, List<int>? positions) {
  final lower = target.lower;
  final start = _windowStart(query, lower, from);
  if (start == null) {
    return null;
  }
  var score = 0;
  var q = 0;
  var previousMatched = false;
  var inGap = false;
  for (var i = start; i < lower.length && q < query.length; i++) {
    if (lower.codeUnitAt(i) == query.codeUnitAt(q)) {
      score += _match + _boundary(target.path, i);
      if (previousMatched) {
        score += _consecutive;
      }
      positions?.add(i);
      q++;
      previousMatched = true;
      inGap = false;
    } else {
      score -= inGap ? _gapExtension : _gapStart;
      previousMatched = false;
      inGap = true;
    }
  }
  return score;
}

/// The bonus for a match at [index] of [path]: the start of a segment, of
/// a word, or a lower-to-upper case change.
int _boundary(String path, int index) {
  if (index == 0) {
    return _segmentStart;
  }
  final previous = path.codeUnitAt(index - 1);
  if (previous == 0x2F) {
    return _segmentStart; // '/'
  }
  if (previous == 0x5F ||
      previous == 0x2D ||
      previous == 0x2E ||
      previous == 0x20) {
    return _wordStart; // '_', '-', '.', ' '
  }
  final current = path.codeUnitAt(index);
  final previousLower = previous >= 0x61 && previous <= 0x7A;
  final currentUpper = current >= 0x41 && current <= 0x5A;
  return previousLower && currentUpper ? _camel : 0;
}

/// Lower case with one code unit per code unit, so that indices into the
/// result are indices into [text]. When lower-casing would change the
/// length (a dotted capital I becomes two code units), only ASCII letters
/// are lowered.
String _lower(String text) {
  final lower = text.toLowerCase();
  if (lower.length == text.length) {
    return lower;
  }
  return String.fromCharCodes([
    for (final unit in text.codeUnits)
      unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit,
  ]);
}
