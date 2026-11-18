/// Search across files (Phase 4 W6): what the Search panel asks for and what
/// comes back, whichever engine searched. A project is searched by the
/// runtime's ripgrep while the runtime is ready, a folder from shared storage
/// by CodeForge's own scan (android/…/search/, pigeons/search_api.dart).
library;

/// What to look for, and in which files.
final class SearchQuery {
  const SearchQuery({
    required this.text,
    this.caseSensitive = false,
    this.regex = false,
    this.wholeWord = false,
    this.includes = const [],
    this.excludes = const [],
  });

  final String text;
  final bool caseSensitive;
  final bool regex;
  final bool wholeWord;

  /// A file must match one of these globs to be searched; none means every
  /// file. A plain name, such as `src`, also means everything inside it.
  final List<String> includes;

  /// Files and folders these globs match are left out.
  final List<String> excludes;

  /// The globs in a field as the user typed them: separated by commas,
  /// blanks dropped (VS Code's form).
  static List<String> globsOf(String field) => [
    for (final part in field.split(','))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  SearchQuery copyWith({
    String? text,
    bool? caseSensitive,
    bool? regex,
    bool? wholeWord,
    List<String>? includes,
    List<String>? excludes,
  }) => SearchQuery(
    text: text ?? this.text,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    regex: regex ?? this.regex,
    wholeWord: wholeWord ?? this.wholeWord,
    includes: includes ?? this.includes,
    excludes: excludes ?? this.excludes,
  );

  @override
  bool operator ==(Object other) =>
      other is SearchQuery &&
      other.text == text &&
      other.caseSensitive == caseSensitive &&
      other.regex == regex &&
      other.wholeWord == wholeWord &&
      _sameList(other.includes, includes) &&
      _sameList(other.excludes, excludes);

  @override
  int get hashCode => Object.hash(
    text,
    caseSensitive,
    regex,
    wholeWord,
    Object.hashAll(includes),
    Object.hashAll(excludes),
  );

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

/// One matching line. Offsets count UTF-16 code units, as Dart's strings
/// and the editor do.
final class SearchLine {
  const SearchLine({
    required this.line,
    required this.column,
    required this.preview,
    this.previewStart = 0,
    this.cutEnd = false,
    this.ranges = const [],
    this.matches = 1,
  });

  /// 1-based.
  final int line;

  /// 1-based, in the whole line: where its first match starts, and where
  /// the editor puts the cursor.
  final int column;

  /// The line, or the part of it around its first match when it is long.
  final String preview;

  /// Where [preview] starts in the line: 0 unless it was cut before it.
  final int previewStart;

  /// Whether the line goes on after [preview].
  final bool cutEnd;

  /// The matches inside [preview], as start and end offsets in pairs.
  final List<int> ranges;

  /// Matches in the whole line.
  final int matches;
}

/// One file's matching lines, in order.
final class SearchFileResult {
  const SearchFileResult({required this.path, required this.lines});

  /// The workspace path: relative to its top, '/'-separated.
  final String path;

  final List<SearchLine> lines;

  /// Matches in the file's lines.
  int get matches => lines.fold(0, (sum, line) => sum + line.matches);
}

/// How a search ended.
enum SearchOutcome {
  /// It looked everywhere it could.
  done,

  /// It stopped at a cap: too many results, or too many files.
  limit,

  /// It was stopped, or a newer search replaced it.
  cancelled,

  failed;

  static SearchOutcome fromCode(String code) => switch (code) {
    'done' => done,
    'limit' => limit,
    'cancelled' => cancelled,
    _ => failed,
  };
}

/// Which engine searched.
enum SearchEngine {
  /// The runtime's ripgrep, for a project while the runtime is ready.
  ripgrep,

  /// CodeForge's own scan: a folder from shared storage, or a project while
  /// the runtime is not ready.
  scan;

  static SearchEngine fromCode(String code) =>
      code == 'ripgrep' ? ripgrep : scan;
}

/// Why a search failed.
enum SearchProblem {
  /// Nothing to look for, or a pattern or glob that does not compile.
  badQuery,

  /// The folder is gone.
  notFound,

  /// The app lost its access to the folder.
  accessLost,

  /// It ran past its time limit.
  timedOut,

  failed;

  static SearchProblem? fromCode(String? code) => switch (code) {
    null => null,
    'bad_query' => badQuery,
    'not_found' => notFound,
    'access_lost' => accessLost,
    'timed_out' => timedOut,
    _ => failed,
  };
}

/// The end of a search, with its counts.
final class SearchSummary {
  const SearchSummary({
    required this.outcome,
    this.engine = SearchEngine.scan,
    this.problem,
    this.detail,
    this.filesSearched,
    this.filesMatched = 0,
    this.lines = 0,
    this.matches = 0,
    this.skippedBinary = 0,
    this.skippedLarge = 0,
    this.skippedNotText = 0,
    this.skippedLongLines = 0,
    this.unreadable = 0,
    this.firstResultMs,
    this.elapsedMs = 0,
  });

  /// A search that failed before it ran.
  const SearchSummary.failed(SearchProblem this.problem, String this.detail)
    : outcome = SearchOutcome.failed,
      engine = SearchEngine.scan,
      filesSearched = null,
      filesMatched = 0,
      lines = 0,
      matches = 0,
      skippedBinary = 0,
      skippedLarge = 0,
      skippedNotText = 0,
      skippedLongLines = 0,
      unreadable = 0,
      firstResultMs = null,
      elapsedMs = 0;

  final SearchOutcome outcome;
  final SearchEngine engine;
  final SearchProblem? problem;

  /// Why it failed, or a warning (files that could not be read).
  final String? detail;

  /// Files read; null for ripgrep, which does not report it.
  final int? filesSearched;
  final int filesMatched;
  final int lines;
  final int matches;

  /// Files left out: binary, over 10 MiB, not UTF-8 text.
  final int skippedBinary;
  final int skippedLarge;
  final int skippedNotText;

  /// ripgrep's lines too long to pass on.
  final int skippedLongLines;

  /// Folders or files that could not be read.
  final int unreadable;

  /// On the host, from the start to the first file with a match.
  final int? firstResultMs;

  /// On the host, from the start to the end.
  final int elapsedMs;

  /// Files left out for what they hold.
  int get skipped => skippedBinary + skippedLarge + skippedNotText;
}
